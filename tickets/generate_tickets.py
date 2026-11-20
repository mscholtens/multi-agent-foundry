"""Generate sample IT helpdesk ticket PDFs for the demo."""
from pathlib import Path
from fpdf import FPDF

TICKETS = [
    {
        "filename": "ticket_A.pdf",
        "id": "TKT-2024-001",
        "submitter": "Sarah Chen",
        "email": "s.chen@company.example",
        "asset_tag": "LT-3821",
        "subject": "VPN not connecting after password change",
        "priority": "Medium",
        "body": (
            "Since changing my Active Directory password yesterday afternoon, my VPN\n"
            "client (GlobalProtect) keeps failing with an 'authentication failed' error.\n\n"
            "I've tried restarting my laptop and re-entering my credentials several times.\n"
            "I'm working from home today and this is completely blocking my access to\n"
            "internal systems. I've been unable to work since 8am.\n\n"
            "Please help as soon as possible."
        ),
    },
    {
        "filename": "ticket_B.pdf",
        "id": "TKT-2024-002",
        "submitter": "James Miller",
        "email": "j.miller@company.example",
        "asset_tag": "LT-4892",
        "subject": "Please install Slack on my work laptop",
        "priority": "Low",
        "body": (
            "Hi IT team,\n\n"
            "Could you please install the Slack desktop application on my work laptop\n"
            "(asset tag LT-4892)?\n\n"
            "Our new project team uses Slack for all communication and I need it set up\n"
            "before the sprint kick-off on Monday morning.\n\n"
            "Happy to be available for a remote session if needed.\n\n"
            "Thank you."
        ),
    },
    {
        "filename": "ticket_C.pdf",
        "id": "TKT-2024-003",
        "submitter": "Bob",
        "email": "bob@company.example",
        "asset_tag": "",
        "subject": "Computer not working",
        "priority": "",
        "body": (
            "Hi,\n\n"
            "My computer is broken and not working properly since this morning.\n"
            "It's very slow and sometimes shows errors.\n\n"
            "I need it fixed ASAP. It's really annoying and I can't do my work properly.\n\n"
            "Please send someone."
        ),
    },
    {
        "filename": "ticket_D.pdf",
        "id": "TKT-2024-004",
        "submitter": "Emma Watts (PA to CEO)",
        "email": "e.watts@company.example",
        "asset_tag": "LT-0001",
        "subject": "URGENT - CEO laptop won't boot - board meeting in 90 minutes",
        "priority": "Critical",
        "body": (
            "URGENT\n\n"
            "Marcus Thompson's laptop (asset tag LT-0001) is showing a blue screen on\n"
            "startup and will not boot. He has a board presentation in 90 minutes and\n"
            "all materials are on the device.\n\n"
            "We need either immediate on-site support or a loaner laptop configured ASAP.\n\n"
            "Marcus is on Floor 5, office 5.01.\n\n"
            "Please treat this as top priority."
        ),
    },
    {
        "filename": "ticket_E.pdf",
        "id": "TKT-2024-005",
        "submitter": "Lisa Rodriguez",
        "email": "l.rodriguez@company.example",
        "asset_tag": "DT-2204",
        "subject": "Multiple issues: slow PC, printer offline, Outlook not syncing",
        "priority": "Medium",
        "body": (
            "I'm having three separate issues that all started around 9am today:\n\n"
            "1. My PC (DT-2204) is extremely slow - taking over 5 minutes to boot and\n"
            "   applications are unresponsive.\n\n"
            "2. The shared printer on Floor 3 near the kitchen (HP LaserJet,\n"
            "   IP 192.168.1.45) is showing as 'offline' for everyone on the floor,\n"
            "   not just me.\n\n"
            "3. My Outlook has been stuck on 'Updating Inbox' for over 2 hours.\n"
            "   I'm not receiving any emails.\n\n"
            "I'm not sure if these are related. Please advise."
        ),
    },
]


def make_pdf(ticket: dict, out_path: Path):
    pdf = FPDF()
    pdf.add_page()
    pdf.set_margins(20, 20, 20)

    # Header
    pdf.set_font("Helvetica", "B", 16)
    pdf.cell(0, 10, "IT Helpdesk Support Ticket", ln=True)
    pdf.set_draw_color(100, 100, 100)
    pdf.set_line_width(0.5)
    pdf.line(20, pdf.get_y(), 190, pdf.get_y())
    pdf.ln(4)

    # Metadata table
    pdf.set_font("Helvetica", "B", 10)
    def row(label, value):
        pdf.set_font("Helvetica", "B", 10)
        pdf.cell(40, 7, label, border=0)
        pdf.set_font("Helvetica", "", 10)
        pdf.cell(0, 7, value or "—", ln=True)

    row("Ticket ID:", ticket["id"])
    row("Submitted by:", ticket["submitter"])
    row("Email:", ticket["email"])
    row("Asset tag:", ticket["asset_tag"] or "-")
    row("Priority:", ticket["priority"] or "-")
    pdf.ln(2)

    # Subject
    pdf.set_font("Helvetica", "B", 11)
    pdf.cell(0, 8, f"Subject: {ticket['subject']}", ln=True)
    pdf.line(20, pdf.get_y(), 190, pdf.get_y())
    pdf.ln(4)

    # Body
    pdf.set_font("Helvetica", "", 10)
    pdf.multi_cell(0, 6, ticket["body"])

    pdf.output(str(out_path))
    print(f"  Created {out_path.name}")


def main():
    out_dir = Path(__file__).parent
    for ticket in TICKETS:
        make_pdf(ticket, out_dir / ticket["filename"])
    print("Done.")


if __name__ == "__main__":
    main()
