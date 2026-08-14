"""Egress broker — a protocol-transparent OpenAI-compatible proxy.

The request body is never deserialised and never rewritten. Doing so would
introduce the custom routing layer the architecture excludes, and would
normalise fields the gateway interprets. The only header this proxy modifies
is the authorisation header: an internal token, valid on this host alone, is
replaced by the real gateway credential, which the agentic runtime never
holds.

Accounting works the same way, and for the same reason. Asking the gateway for
the cost by adding a field to the request would mean rewriting the body.
Estimating it from a local price table would create a second source of truth
that diverges silently at every tariff change. So the request is forwarded
untouched, the generation identifier the gateway returns is noted, and the
real cost is requested afterwards on a separate channel, with the credential
only this process holds. The consequence worth knowing is that the spending
cap acts one request late: an overrun is detected on the call after the one
that caused it.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import signal
import time
from collections import defaultdict

import httpx
import uvicorn
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import (
    JSONResponse,
    PlainTextResponse,
    Response,
    StreamingResponse,
)
from starlette.routing import Route

LOG = logging.getLogger("egress-broker")

# --------------------------------------------------------------- configuration
UPSTREAM = os.environ.get("BROKER_UPSTREAM", "https://openrouter.ai/api/v1")
TOKENS_FILE = os.environ["BROKER_TOKENS_FILE"]
CREDS_FILE = os.environ["BROKER_CREDENTIALS_FILE"]
LISTEN_HOST = os.environ.get("BROKER_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("BROKER_LISTEN_PORT", "8081"))
BUDGET_SOFT = float(os.environ.get("BROKER_BUDGET_SOFT", "0"))
BUDGET_HARD = float(os.environ.get("BROKER_BUDGET_HARD", "0"))
BUDGET_WINDOW = int(os.environ.get("BROKER_BUDGET_WINDOW_SECONDS", "86400"))
MAX_CONN = int(os.environ.get("BROKER_MAX_CONNECTIONS", "32"))
RESERVE_INT = float(os.environ.get("BROKER_RESERVE_INTERACTIVE", "0.5"))
TIMEOUT = float(os.environ.get("BROKER_TIMEOUT_SECONDS", "600"))
RETRY_AFTER = os.environ.get("BROKER_RETRY_AFTER", "300")

# Hop-by-hop headers are not forwarded (RFC 9110 section 7.6.1).
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}

GEN_ID_RE = re.compile(rb'"id"\s*:\s*"([^"]+)"')

# ------------------------------------------------------------------- metrics
M_COST = Counter(
    "hermes_inference_cost_usd_total",
    "Attributed inference cost, in USD",
    ["plane", "profile", "purpose"],
)
M_REQ = Counter(
    "hermes_inference_requests_total",
    "Inference requests forwarded",
    ["plane", "profile", "purpose", "status"],
)
M_LAT = Histogram(
    "hermes_inference_latency_seconds",
    "Latency until the first useful byte",
    ["plane", "purpose"],
)
M_BUDGET = Gauge(
    "hermes_broker_budget_used_ratio",
    "Share of the budget consumed over the current window",
    ["plane", "profile"],
)
M_UNATTR = Counter(
    "hermes_broker_cost_unattributed_total",
    "Cost that could not be attributed to a generation identifier",
)
M_INFLIGHT = Gauge(
    "hermes_broker_inflight_requests",
    "Requests in flight towards the gateway",
    ["plane"],
)


class State:
    """State reloadable without a restart, on SIGHUP."""

    def __init__(self) -> None:
        self.tokens: dict[str, dict] = {}
        self.creds: dict[str, str] = {}
        self.spend: dict[tuple[str, str], float] = defaultdict(float)
        self.window_start: float = time.time()
        self.sem_all = asyncio.Semaphore(MAX_CONN)

        # Capacity reserved for the interactive plane: an unattended batch
        # must not be able to occupy every connection towards the gateway.
        programmatic = max(1, int(MAX_CONN * (1.0 - RESERVE_INT)))
        self.sem_prog = asyncio.Semaphore(programmatic)

        self.reload()

    def reload(self) -> None:
        with open(TOKENS_FILE, encoding="utf-8") as handle:
            self.tokens = json.load(handle)
        with open(CREDS_FILE, encoding="utf-8") as handle:
            self.creds = json.load(handle)
        LOG.info(
            "reloaded %d tokens and %d credentials",
            len(self.tokens),
            len(self.creds),
        )

    def roll_window(self) -> None:
        if time.time() - self.window_start >= BUDGET_WINDOW:
            self.spend.clear()
            self.window_start = time.time()

    def over_hard_cap(self, plane: str, profile: str) -> bool:
        self.roll_window()
        return BUDGET_HARD > 0 and self.spend[(plane, profile)] >= BUDGET_HARD

    def add_cost(self, plane: str, profile: str, purpose: str, usd: float) -> None:
        self.roll_window()
        self.spend[(plane, profile)] += usd
        M_COST.labels(plane, profile, purpose).inc(usd)
        if BUDGET_HARD > 0:
            M_BUDGET.labels(plane, profile).set(
                self.spend[(plane, profile)] / BUDGET_HARD
            )
        if BUDGET_SOFT > 0 and self.spend[(plane, profile)] >= BUDGET_SOFT:
            LOG.warning(
                "soft budget threshold crossed: plane=%s profile=%s", plane, profile
            )


STATE = State()
CLIENT: httpx.AsyncClient | None = None


async def account_cost(gen_id: str, ident: dict) -> None:
    """Ask the gateway for the real cost, on a channel of its own.

    This is the only way of accounting without touching the request body. The
    cost is not immediately available, so the lookup is retried with a short
    backoff before the sample is given up as unattributed.
    """
    assert CLIENT is not None

    cred = STATE.creds.get(ident["credential"])
    if not cred:
        M_UNATTR.inc()
        return

    for delay in (0.5, 2.0, 5.0):
        await asyncio.sleep(delay)
        try:
            response = await CLIENT.get(
                f"{UPSTREAM}/generation",
                params={"id": gen_id},
                headers={"Authorization": f"Bearer {cred}"},
                timeout=30.0,
            )
            if response.status_code != 200:
                continue
            data = response.json().get("data", {})
            usd = float(data.get("total_cost") or 0.0)
            STATE.add_cost(
                ident["plane"], ident["profile"], ident["purpose"], usd
            )
            return
        except (httpx.HTTPError, ValueError, KeyError):
            continue

    M_UNATTR.inc()


def identify(request: Request) -> dict | None:
    """Resolve the internal token into plane, profile, purpose and credential.

    One token per profile rather than per plane. That is what makes the cost
    perimeter measurable per profile without adding a header to the protocol,
    which would break protocol transparency.
    """
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        return None
    return STATE.tokens.get(auth[7:].strip())


def upstream_headers(request: Request, cred: str) -> dict[str, str]:
    headers = {
        key: value
        for key, value in request.headers.items()
        if key.lower() not in HOP_BY_HOP and key.lower() != "authorization"
    }
    headers["Authorization"] = f"Bearer {cred}"

    referer = os.environ.get("BROKER_REFERER")
    app_title = os.environ.get("BROKER_APP_TITLE")
    if referer:
        headers.setdefault("HTTP-Referer", referer)
    if app_title:
        headers.setdefault("X-Title", app_title)

    return headers


async def proxy(request: Request) -> Response:
    ident = identify(request)
    if ident is None:
        return JSONResponse(
            {
                "error": {
                    "message": "invalid internal token",
                    "type": "invalid_request_error",
                }
            },
            status_code=401,
        )

    plane, profile = ident["plane"], ident["profile"]
    purpose = ident["purpose"]

    if STATE.over_hard_cap(plane, profile):
        M_REQ.labels(plane, profile, purpose, "429").inc()
        LOG.warning("hard cap reached: plane=%s profile=%s", plane, profile)
        return JSONResponse(
            {
                "error": {
                    "message": "budget exhausted for this profile",
                    "type": "insufficient_quota",
                }
            },
            status_code=429,
            headers={"Retry-After": RETRY_AFTER},
        )

    cred = STATE.creds.get(ident["credential"])
    if not cred:
        M_REQ.labels(plane, profile, purpose, "502").inc()
        return JSONResponse(
            {"error": {"message": "credential unavailable", "type": "api_error"}},
            status_code=502,
        )

    # The body is a sequence of bytes. It is never parsed as JSON.
    body = await request.body()
    url = f"{UPSTREAM}/{request.path_params['path']}"

    assert CLIENT is not None

    semaphores = [STATE.sem_all]
    if plane == "programmatic":
        semaphores.append(STATE.sem_prog)

    started = time.perf_counter()
    for semaphore in semaphores:
        await semaphore.acquire()
    M_INFLIGHT.labels(plane).inc()

    seen: dict[str, str] = {}

    async def release() -> None:
        M_INFLIGHT.labels(plane).dec()
        for semaphore in reversed(semaphores):
            semaphore.release()
        gen_id = seen.get("id")
        if gen_id:
            asyncio.create_task(account_cost(gen_id, ident))
        else:
            M_UNATTR.inc()

    try:
        upstream_request = CLIENT.build_request(
            request.method,
            url,
            headers=upstream_headers(request, cred),
            params=request.query_params,
            content=body,
        )
        upstream = await CLIENT.send(upstream_request, stream=True)
    except httpx.HTTPError as exc:
        await release()
        M_REQ.labels(plane, profile, purpose, "502").inc()
        LOG.error("error towards the gateway: %s", exc)
        return JSONResponse(
            {"error": {"message": "gateway unreachable", "type": "api_error"}},
            status_code=502,
        )

    M_LAT.labels(plane, purpose).observe(time.perf_counter() - started)
    M_REQ.labels(plane, profile, purpose, str(upstream.status_code)).inc()

    async def body_iter():
        try:
            async for chunk in upstream.aiter_raw():
                if "id" not in seen:
                    found = GEN_ID_RE.search(chunk)
                    if found:
                        seen["id"] = found.group(1).decode("utf-8", "replace")
                # The bytes leave exactly as they arrived.
                yield chunk
        finally:
            await upstream.aclose()
            await release()

    passthrough = {
        key: value
        for key, value in upstream.headers.items()
        if key.lower() not in HOP_BY_HOP
    }

    return StreamingResponse(
        body_iter(),
        status_code=upstream.status_code,
        headers=passthrough,
        media_type=upstream.headers.get("content-type"),
    )


async def healthz(_: Request) -> Response:
    return JSONResponse(
        {
            "status": "healthy",
            "tokens": len(STATE.tokens),
            "credentials": len(STATE.creds),
        }
    )


async def metrics(_: Request) -> Response:
    return PlainTextResponse(
        generate_latest().decode("utf-8"), media_type=CONTENT_TYPE_LATEST
    )


async def on_startup() -> None:
    global CLIENT
    CLIENT = httpx.AsyncClient(
        timeout=httpx.Timeout(TIMEOUT, connect=10.0),
        limits=httpx.Limits(
            max_connections=MAX_CONN, max_keepalive_connections=MAX_CONN
        ),
        follow_redirects=False,
    )
    loop = asyncio.get_running_loop()

    # Rotation without a rebuild is the operational benefit of holding the
    # credential here rather than in the agentic runtime.
    loop.add_signal_handler(signal.SIGHUP, STATE.reload)
    LOG.info("broker listening on %s:%d, upstream %s", LISTEN_HOST, LISTEN_PORT, UPSTREAM)


async def on_shutdown() -> None:
    if CLIENT is not None:
        await CLIENT.aclose()


app = Starlette(
    routes=[
        Route("/healthz", healthz, methods=["GET"]),
        Route("/metrics", metrics, methods=["GET"]),
        Route(
            "/v1/{path:path}",
            proxy,
            methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
        ),
    ],
    on_startup=[on_startup],
    on_shutdown=[on_shutdown],
)


def run() -> None:
    logging.basicConfig(
        level=os.environ.get("BROKER_LOG_LEVEL", "INFO"),
        format='{"ts":"%(asctime)s","level":"%(levelname)s",'
        '"svc":"egress-broker","msg":"%(message)s"}',
    )
    # The access log would record paths and query strings. They carry no
    # conversational content, but the discipline is that metrics and
    # identifiers leave this process, and request traces do not.
    uvicorn.run(
        app,
        host=LISTEN_HOST,
        port=LISTEN_PORT,
        access_log=False,
        log_config=None,
    )


if __name__ == "__main__":
    run()
