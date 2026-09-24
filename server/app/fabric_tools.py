"""Restricted Microsoft Fabric retrieval and support-ticket tools."""

import asyncio
import hashlib
import json
import logging
import re
import time
import uuid
from datetime import UTC, datetime
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
        self._ticket_results: dict[tuple[str, str], dict[str, Any]] = {}
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
            raise PermissionError(
                "Customer scope does not match the authenticated customer."
            )
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
                if str(row.get("customer_key", "")) == customer_key
            ]
            self._log(
                "fabric_retrieve_business_data",
                started,
                True,
                len(safe_rows),
                correlation_id,
            )
            return {
                "results": safe_rows,
                "result_count": len(safe_rows),
                "message": "No authorized matching records were found."
                if not safe_rows
                else "OK",
            }
        except Exception:
            self._log(
                "fabric_retrieve_business_data", started, False, 0, correlation_id
            )
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
                cache_key = (
                    validated["customer_key"],
                    validated["idempotency_key"],
                )
                existing = self._ticket_results.get(cache_key)
                if existing:
                    self._log("create_support_ticket", started, True, 1, correlation_id)
                    return existing
                result = await self._backend.create_ticket(validated)
                if not _TICKET.fullmatch(str(result.get("ticket_id", ""))):
                    raise RuntimeError(
                        "Ticket writer returned an invalid ticket reference."
                    )
                self._ticket_results[cache_key] = result
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
            raise PermissionError(
                "Customer scope does not match the authenticated customer."
            )
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

    async def close(self) -> None:
        close = getattr(self._backend, "close", None)
        if close:
            await close()


class FabricHttpBackend:
    """Call a published Fabric Data Agent and a restricted ticket-write function."""

    def __init__(
        self,
        *,
        workspace_id: str,
        lakehouse_id: str,
        data_agent_id: str,
        ticket_write_endpoint: str,
        read_client_id: str,
        write_client_id: str,
        timeout_seconds: int = 20,
    ):
        self._data_agent_url = (
            "https://api.fabric.microsoft.com/v1/mcp/workspaces/"
            f"{workspace_id}/dataagents/{data_agent_id}/agent"
        )
        self._workspace_id = workspace_id
        self._lakehouse_id = lakehouse_id
        self._ticket_write_endpoint = ticket_write_endpoint
        self._read_credential = ManagedIdentityCredential(client_id=read_client_id)
        self._write_credential = ManagedIdentityCredential(client_id=write_client_id)
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
        content = await self._call_data_agent(prompt)
        if not isinstance(content, list) or not all(
            isinstance(item, dict) for item in content
        ):
            raise RuntimeError("Fabric Data Agent returned an unexpected response.")
        return content

    async def _call_data_agent(self, prompt: str) -> Any:
        token = await self._read_credential.get_token(
            "https://api.fabric.microsoft.com/.default"
        )
        headers = {
            "Authorization": "Bearer " + token.token,
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        async with aiohttp.ClientSession(timeout=self._timeout) as session:
            initialized, session_id = await self._mcp_request(
                session,
                headers,
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "protocolVersion": "2025-06-18",
                        "capabilities": {},
                        "clientInfo": {
                            "name": "call-center-voice-agent",
                            "version": "1.0",
                        },
                    },
                },
            )
            if initialized.get("error"):
                raise RuntimeError("Fabric MCP initialization failed.")
            if session_id:
                headers["Mcp-Session-Id"] = session_id
            await self._mcp_request(
                session,
                headers,
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
            )
            tools_response, _ = await self._mcp_request(
                session,
                headers,
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            )
            tools = tools_response.get("result", {}).get("tools", [])
            if not tools:
                raise RuntimeError("Fabric Data Agent exposed no MCP tools.")
            tool = tools[0]
            properties = tool.get("inputSchema", {}).get("properties", {})
            argument_name = next(
                (
                    name
                    for name in ("question", "query", "input", "prompt")
                    if name in properties
                ),
                None,
            )
            if not argument_name:
                raise RuntimeError("Fabric Data Agent tool has no query argument.")
            call_response, _ = await self._mcp_request(
                session,
                headers,
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": {
                        "name": tool["name"],
                        "arguments": {argument_name: prompt},
                    },
                },
            )
        result = call_response.get("result", {})
        if result.get("isError"):
            raise RuntimeError("Fabric Data Agent query failed.")
        structured = result.get("structuredContent")
        if isinstance(structured, list):
            return structured
        if isinstance(structured, dict):
            for key in ("results", "records", "rows"):
                if isinstance(structured.get(key), list):
                    return structured[key]
        text = "\n".join(
            item.get("text", "")
            for item in result.get("content", [])
            if item.get("type") == "text"
        )
        return json.loads(text or "[]")

    async def _mcp_request(
        self,
        session: aiohttp.ClientSession,
        headers: dict[str, str],
        payload: dict[str, Any],
    ) -> tuple[dict[str, Any], str]:
        async with session.post(
            self._data_agent_url, headers=headers, json=payload
        ) as response:
            if response.status < 200 or response.status >= 300:
                raise RuntimeError(
                    f"Fabric MCP request failed with HTTP {response.status}."
                )
            body = await response.text()
            session_id = response.headers.get(
                "Mcp-Session-Id", headers.get("Mcp-Session-Id", "")
            )
        if not body:
            return {}, session_id
        if body.lstrip().startswith("{"):
            return json.loads(body), session_id
        data_lines = [
            line.removeprefix("data:").strip()
            for line in body.splitlines()
            if line.startswith("data:")
        ]
        if not data_lines:
            raise RuntimeError("Fabric MCP returned an unexpected response.")
        return json.loads(data_lines[-1]), session_id

    async def create_ticket(self, request: dict[str, Any]) -> dict[str, Any]:
        customer_rows = await self.retrieve(
            {"intent": "customer", "customer_key": request["customer_key"]}
        )
        if not any(
            row.get("customer_key") == request["customer_key"] for row in customer_rows
        ):
            raise ToolValidationError("The authenticated customer was not found.")
        if request.get("product_key"):
            installed_rows = await self.retrieve(
                {
                    "intent": "installed_products",
                    "customer_key": request["customer_key"],
                    "product_key": request["product_key"],
                }
            )
            if not any(
                row.get("customer_key") == request["customer_key"]
                and row.get("product_key") == request["product_key"]
                for row in installed_rows
            ):
                raise ToolValidationError(
                    "The product is not installed for the authenticated customer."
                )
        if self._ticket_write_endpoint:
            return await self._post(
                self._ticket_write_endpoint,
                request,
                "https://api.fabric.microsoft.com/.default",
            )
        return await self._append_ticket_to_onelake(request)

    async def _append_ticket_to_onelake(
        self, request: dict[str, Any]
    ) -> dict[str, Any]:
        idempotency_scope = f"{request['customer_key']}:{request['idempotency_key']}"
        digest = hashlib.sha256(idempotency_scope.encode()).hexdigest()
        created_at = datetime.now(UTC).replace(microsecond=0)
        ticket = {
            **request,
            "ticket_id": f"TKT-{created_at.year}-{digest[:12].upper()}",
            "status": "Open",
            "created_at": created_at.isoformat().replace("+00:00", "Z"),
            "audit": {
                "actor_id": request["actor_id"],
                "conversation_id": request["conversation_id"],
                "user_confirmed": True,
            },
        }
        content = json.dumps(ticket, ensure_ascii=False).encode()
        directory_url = (
            "https://onelake.dfs.fabric.microsoft.com/"
            f"{self._workspace_id}/{self._lakehouse_id}/Files/raw/"
            "support-ticket-inbox"
        )
        url = f"{directory_url}/{digest}.json"
        temporary_name = f".{digest}.{uuid.uuid4().hex}.tmp"
        temporary_url = f"{directory_url}/{temporary_name}"
        rename_source = (
            f"/{self._workspace_id}/{self._lakehouse_id}/Files/raw/"
            f"support-ticket-inbox/{temporary_name}"
        )
        token = await self._write_credential.get_token(
            "https://storage.azure.com/.default"
        )
        headers = {"Authorization": "Bearer " + token.token}
        async with aiohttp.ClientSession(timeout=self._timeout) as session:
            async with session.put(
                f"{directory_url}?resource=directory", headers=headers
            ) as directory_response:
                if directory_response.status not in {201, 409}:
                    raise RuntimeError(
                        "OneLake ticket directory creation failed with HTTP "
                        f"{directory_response.status}."
                    )
            async with session.put(
                f"{temporary_url}?resource=file",
                headers=headers,
            ) as create_response:
                if create_response.status != 201:
                    raise RuntimeError(
                        f"OneLake file creation failed with HTTP {create_response.status}."
                    )
            async with session.patch(
                f"{temporary_url}?action=append&position=0",
                headers={**headers, "Content-Type": "application/json"},
                data=content,
            ) as append_response:
                if append_response.status not in {200, 202}:
                    raise RuntimeError(
                        f"OneLake append failed with HTTP {append_response.status}."
                    )
            async with session.patch(
                f"{temporary_url}?action=flush&position={len(content)}",
                headers=headers,
            ) as flush_response:
                if flush_response.status not in {200, 202}:
                    raise RuntimeError(
                        f"OneLake flush failed with HTTP {flush_response.status}."
                    )
            async with session.put(
                url,
                headers={
                    **headers,
                    "If-None-Match": "*",
                    "x-ms-rename-source": rename_source,
                },
            ) as rename_response:
                if rename_response.status in {409, 412}:
                    async with session.delete(
                        temporary_url, headers=headers
                    ) as _cleanup:
                        pass
                    async with session.get(url, headers=headers) as existing:
                        if existing.status != 200:
                            raise RuntimeError(
                                "Unable to read the existing idempotent ticket."
                            )
                        return await existing.json()
                if rename_response.status not in {200, 201}:
                    raise RuntimeError(
                        f"OneLake commit failed with HTTP {rename_response.status}."
                    )
        return {key: ticket[key] for key in ("ticket_id", "status", "created_at")} | {
            "message": "Your support ticket has been created."
        }

    async def _post(
        self, url: str, payload: dict[str, Any], scope: str
    ) -> dict[str, Any]:
        token = await self._write_credential.get_token(scope)
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
        await self._read_credential.close()
        await self._write_credential.close()
