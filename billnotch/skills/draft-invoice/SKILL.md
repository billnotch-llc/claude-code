---
name: draft-invoice
description: Prepare a draft invoice in BillNotch from a client's unbilled time. Use when the user asks to invoice a client, bill a period, draft an invoice, or see what an invoice would come to.
---

# Draft an invoice in BillNotch

This skill previews and saves drafts. It cannot send, void or mark an invoice paid: the member does that in BillNotch after reviewing the draft.

1. Find the client with `list_clients`. If the user named no client, call `revenue_leaks` and show which clients have uninvoiced work so they can choose.
2. Fix the billing period. Default to the previous calendar month when the user gives none, and say which dates you used.
3. Call `preview_invoice` with `clientId`, `from` and `to` (plus `taxRate` if the user gave one). Nothing is saved.
4. Show the preview: each line with hours, rate and amount, then subtotal, tax and total, and how many time entries it covers.
5. Ask for confirmation. Only after a clear yes, call `create_invoice_draft` with the same arguments.
6. Reply with the invoice number, total and the `url` from the result, and remind the user it is a draft that still has to be reviewed and sent from BillNotch.

Failure cases:

- "No uninvoiced billable time": nothing to bill in that range. Offer a wider period, or `revenue_leaks` to see where the client's unbilled time sits.
- `FORBIDDEN` naming `invoices.draft`: the member's role cannot draft invoices. An organization admin has to do it or change the role.
- `BILLING_LOCKED`: the trial has ended; previews still work, saving does not.

Do not create a draft the user has not seen a preview of. Do not create a second draft for a period you already drafted in this conversation: the first one already claimed those entries.
