"""Restricted Microsoft Fabric retrieval and support-ticket tools."""

import asyncio
import logging
import re
import time
from typing import Any, Protocol

import aiohttp
from azure.identity.aio import ManagedIdentityCredential

logger = logging.getLogger("telemetry.fabric")

_KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_TICKET = re.compile(r"^TKT-[A-Za-z0-9-]{1,40}$")
_PRIORITIES = {"P1", "P2", "P3", "P4"}
_INTENTS = {"customer", "installed_products", "product", "ticket", "similar_cases"}


class FabricBackend(Protocol):
    async def retrieve(self, request: dict[str, str]) -> list[dict[str, Any]]: ...

    async def create_ticket(self, request: dict[str, Any]) -> dict[str, Any]: ...


class ToolValidationError(ValueError):
    """A tool request failed validation."""


class FabricToolService:
    """Enforce authorization, confirmation, and idempotency around Fabric I/O."""

    def __init__(self, backend: FabricBackend):
        self._backend = backend
        self._ticket_results: dict[str, dict[str, Any]] = {}
        self._ticket_lock = asyncio.Lock()

    async def retrieve(
        self,
        *,
        intent: str,
        authorized_customer_key: str,
        customer_key: str | None = None,
        product_key: str | None = None,
        ticket_id: str | None = None,
        query: str | None = None,
        correlation_id: str = "",
    ) -> dict[str, Any]:
        started = time.perf_counter()
        if intent not in _INTENTS:
            raise ToolValidationError("Unsupported retrieval intent.")
        customer_key = customer_key or authorized_customer_key
        self._validate_key("authorized_customer_key", authorized_customer_key)
        self._validate_key("customer_key", customer_key)
        if customer_key != authorized_customer_key:
            raise PermissionError("Customer scope does not match the authenticated customer.")
        if product_key:
            self._validate_key("product_key", product_key)
        if ticket_id and not _TICKET.fullmatch(ticket_id):
            raise ToolValidationError("ticket_id has an invalid format.")
        if query and len(query) > 500:
            raise ToolValidationError("query must not exceed 500 characters.")

        request = {
            key: value
            for key, value in {
                "intent": intent,
                "customer_key": customer_key,
                "product_key": product_key,
                "ticket_id": ticket_id,
                "query": query,
            }.items()
            if value
        }
        try:
            rows = await self._backend.retrieve(request)
            safe_rows = [
                self._safe_result(row)
                for row in rows
                if str(row.get("customer_key", customer_key)) == customer_key
            ]
            self._log("fabric_retrieve_business_data", started, True, len(safe_rows), correlation_id)
            return {
                "results": safe_rows,
                "result_count": len(safe_rows),
                "message": "No authorized matching records were found." if not safe_rows else "OK",
            }
        except Exception:
            self._log("fabric_retrieve_business_data", started, False, 0, correlation_id)
            raise

    async def create_ticket(
        self,
        request: dict[str, Any],
        *,
        authorized_customer_key: str,
        actor_id: str,
        correlation_id: str = "",
    ) -> dict[str, Any]:
        started = time.perf_counter()
        validated = self._validate_ticket(request, authorized_customer_key)
        validated["actor_id"] = actor_id
        try:
            async with self._ticket_lock:
                existing = self._ticket_results.get(validated["idempotency_key"])
                if existing:
                    self._log("create_support_ticket", started, True, 1, correlation_id)
                    return existing
                result = await self._backend.create_ticket(validated)
                if not _TICKET.fullmatch(str(result.get("ticket_id", ""))):
                    raise RuntimeError("Ticket writer returned an invalid ticket reference.")
                self._ticket_results[validated["idempotency_key"]] = result
            self._log("create_support_ticket", started, True, 1, correlation_id)
            return result
        except Exception:
            self._log("create_support_ticket", started, False, 0, correlation_id)
            raise

    @staticmethod
    def _validate_key(name: str, value: str) -> None:
        if not _KEY.fullmatch(value):
            raise ToolValidationError(f"{name} has an invalid format.")

    def _validate_ticket(
        self, request: dict[str, Any], authorized_customer_key: str
    ) -> dict[str, Any]:
        allowed = {
            "customer_key",
            "contact_key",
            "product_key",
            "subject",
            "description",
            "category",
            "priority",
            "channel",
            "user_confirmed",
            "conversation_id",
            "idempotency_key",
        }
        unknown = set(request) - allowed
        if unknown:
            raise ToolValidationError("Unsupported ticket fields were supplied.")
        if request.get("user_confirmed") is not True:
            raise ToolValidationError("Explicit user confirmation is required.")
        customer_key = str(request.get("customer_key", ""))
        self._validate_key("customer_key", customer_key)
        self._validate_key("authorized_customer_key", authorized_customer_key)
        if customer_key != authorized_customer_key:
            raise PermissionError("Customer scope does not match the authenticated customer.")
        for name in ("contact_key", "product_key"):
            if request.get(name):
                self._validate_key(name, str(request[name]))
        subject = str(request.get("subject", "")).strip()
        description = str(request.get("description", "")).strip()
        if not 5 <= len(subject) <= 120:
            raise ToolValidationError("subject must contain 5 to 120 characters.")
        if not 10 <= len(description) <= 4000:
            raise ToolValidationError("description must contain 10 to 4000 characters.")
        priority = str(request.get("priority", ""))
        if priority not in _PRIORITIES:
            raise ToolValidationError("priority must be P1, P2, P3, or P4.")
        conversation_id = str(request.get("conversation_id", ""))
        idempotency_key = str(request.get("idempotency_key", ""))
        self._validate_key("conversation_id", conversation_id)
        self._validate_key("idempotency_key", idempotency_key)
        return {
            **request,
            "subject": subject,
            "description": description,
            "channel": "voice-agent",
        }

    @staticmethod
    def _safe_result(row: dict[str, Any]) -> dict[str, Any]:
        blocked = {"email", "phone", "message_body", "csat_comment"}
        return {key: value for key, value in row.items() if key.lower() not in blocked}

    @staticmethod
    def _log(
        tool: str, started: float, success: bool, result_count: int, correlation_id: str
    ) -> None:
        logger.info(
            "tool=%s status=%s latency_ms=%.0f result_count=%d correlation_id=%s",
            tool,
            "succeeded" if success else "failed",
            (time.perf_counter() - started) * 1000,
            result_count,
            correlation_id,
        )


class FabricHttpBackend:
    """Call a published Fabric Data Agent and a restricted ticket-write function."""

    def __init__(
        self,
        *,
        workspace_id: str,
        data_agent_id: str,
        ticket_write_endpoint: str,
        client_id: str,
        timeout_seconds: int = 20,
    ):
        self._data_agent_url = (
            "https://api.fabric.microsoft.com/v1/workspaces/"
            f"{workspace_id}/dataAgents/{data_agent_id}/chat/completions"
        )
        self._ticket_write_endpoint = ticket_write_endpoint
        self._credential = ManagedIdentityCredential(client_id=client_id)
        self._timeout = aiohttp.ClientTimeout(total=timeout_seconds)

    async def retrieve(self, request: dict[str, str]) -> list[dict[str, Any]]:
        intent = request["intent"]
        filters = {
            key: value
            for key, value in request.items()
            if key in {"customer_key", "product_key", "ticket_id"}
        }
        prompt = (
            f"Intent: {intent}. Apply these mandatory exact-match filters: {filters}. "
            "Return JSON only as an array of records. Include customer_key and source_id "
            "in each record. Exclude email, phone, message_body, and csat_comment. "
            f"Additional search text: {request.get('query', '')}"
        )
        response = await self._post(
            self._data_agent_url,
            {"messages": [{"role": "user", "content": prompt}]},
            "https://api.fabric.microsoft.com/.default",
        )
        content = (
            response.get("choices", [{}])[0]
            .get("message", {})
            .get("content", "[]")
        )
        if isinstance(content, str):
            import json

            content = json.loads(content)
        if not isinstance(content, list) or not all(
            isinstance(item, dict) for item in content
        ):
            raise RuntimeError("Fabric Data Agent returned an unexpected response.")
        return content

    async def create_ticket(self, request: dict[str, Any]) -> dict[str, Any]:
        if not self._ticket_write_endpoint:
            raise RuntimeError("FABRIC_TICKET_WRITE_ENDPOINT is not configured.")
        return await self._post(
            self._ticket_write_endpoint,
            request,
            "https://api.fabric.microsoft.com/.default",
        )

    async def _post(
        self, url: str, payload: dict[str, Any], scope: str
    ) -> dict[str, Any]:
        token = await self._credential.get_token(scope)
        headers = {
            "Authorization": "Bearer " + token.token,
            "Content-Type": "application/json",
        }
        async with aiohttp.ClientSession(timeout=self._timeout) as session:
            async with session.post(url, headers=headers, json=payload) as response:
                if response.status < 200 or response.status >= 300:
                    raise RuntimeError(
                        f"Fabric request failed with HTTP {response.status}."
                    )
                result = await response.json()
        if not isinstance(result, dict):
            raise RuntimeError("Fabric returned an unexpected response.")
        return result

    async def close(self) -> None:
        await self._credential.close()
