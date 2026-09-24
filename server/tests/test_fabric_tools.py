import asyncio
import logging
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))

from app.fabric_tools import FabricToolService, ToolValidationError


class FakeBackend:
    def __init__(self):
        self.created = []
        self.rows = []

    async def retrieve(self, request):
        return self.rows

    async def create_ticket(self, request):
        self.created.append(request)
        return {
            "ticket_id": "TKT-2026-002852",
            "status": "Open",
            "created_at": "2026-09-24T10:15:00Z",
            "message": "Your support ticket has been created.",
        }


def ticket_request(**overrides):
    request = {
        "customer_key": "CUST-001",
        "contact_key": "CONTACT-1",
        "product_key": "PROD-1",
        "subject": "Conveyor is stopped",
        "description": "The conveyor stopped after displaying fault E42.",
        "priority": "P2",
        "user_confirmed": True,
        "conversation_id": "conversation-1",
        "idempotency_key": "request-1",
    }
    request.update(overrides)
    return request


class FabricToolTests(unittest.TestCase):
    def setUp(self):
        self.backend = FakeBackend()
        self.service = FabricToolService(self.backend)

    def test_retrieval_is_customer_scoped_and_removes_pii(self):
        self.backend.rows = [
            {
                "customer_key": "CUST-001",
                "product_key": "PROD-1",
                "source_id": "installed-base/1",
                "email": "private@example.test",
                "message_body": "private",
            }
        ]

        result = asyncio.run(
            self.service.retrieve(
                intent="installed_products",
                authorized_customer_key="CUST-001",
                customer_key="CUST-001",
            )
        )

        self.assertEqual(result["result_count"], 1)
        self.assertNotIn("email", result["results"][0])
        self.assertNotIn("message_body", result["results"][0])
        self.assertEqual(result["results"][0]["source_id"], "installed-base/1")

    def test_retrieval_rejects_cross_customer_access(self):
        with self.assertRaises(PermissionError):
            asyncio.run(
                self.service.retrieve(
                    intent="ticket",
                    authorized_customer_key="CUST-001",
                    customer_key="CUST-002",
                    ticket_id="TKT-2026-1",
                )
            )

    def test_retrieval_drops_rows_without_customer_scope(self):
        self.backend.rows = [{"product_key": "PROD-1", "source_id": "product/1"}]

        result = asyncio.run(
            self.service.retrieve(
                intent="product",
                authorized_customer_key="CUST-001",
                product_key="PROD-1",
            )
        )

        self.assertEqual(result["results"], [])

    def test_empty_retrieval_does_not_invent_results(self):
        result = asyncio.run(
            self.service.retrieve(
                intent="similar_cases",
                authorized_customer_key="CUST-001",
                product_key="PROD-1",
            )
        )

        self.assertEqual(result["results"], [])
        self.assertIn("No authorized", result["message"])

    def test_ticket_requires_explicit_confirmation(self):
        with self.assertRaises(ToolValidationError):
            asyncio.run(
                self.service.create_ticket(
                    ticket_request(user_confirmed=False),
                    authorized_customer_key="CUST-001",
                    actor_id="agent-1",
                )
            )
        self.assertEqual(self.backend.created, [])

    def test_ticket_is_created_exactly_once_for_idempotency_key(self):
        first = asyncio.run(
            self.service.create_ticket(
                ticket_request(),
                authorized_customer_key="CUST-001",
                actor_id="agent-1",
            )
        )
        second = asyncio.run(
            self.service.create_ticket(
                ticket_request(),
                authorized_customer_key="CUST-001",
                actor_id="agent-1",
            )
        )

        self.assertEqual(first, second)
        self.assertEqual(len(self.backend.created), 1)

    def test_idempotency_is_scoped_to_authenticated_customer(self):
        asyncio.run(
            self.service.create_ticket(
                ticket_request(),
                authorized_customer_key="CUST-001",
                actor_id="agent-1",
            )
        )
        asyncio.run(
            self.service.create_ticket(
                ticket_request(customer_key="CUST-002"),
                authorized_customer_key="CUST-002",
                actor_id="agent-1",
            )
        )

        self.assertEqual(len(self.backend.created), 2)

    def test_ticket_rejects_model_owned_server_fields(self):
        with self.assertRaises(ToolValidationError):
            asyncio.run(
                self.service.create_ticket(
                    ticket_request(ticket_id="TKT-FORGED"),
                    authorized_customer_key="CUST-001",
                    actor_id="agent-1",
                )
            )

    def test_telemetry_excludes_ticket_content(self):
        with self.assertLogs("telemetry.fabric", logging.INFO) as logs:
            asyncio.run(
                self.service.create_ticket(
                    ticket_request(description="Sensitive machine details."),
                    authorized_customer_key="CUST-001",
                    actor_id="agent-1",
                    correlation_id="correlation-1",
                )
            )

        output = "\n".join(logs.output)
        self.assertIn("create_support_ticket", output)
        self.assertIn("correlation-1", output)
        self.assertNotIn("Sensitive machine details", output)


if __name__ == "__main__":
    unittest.main()
