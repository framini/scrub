"""Writes labelled training text for the address model as JSON lines.

Each line is {"text": ..., "spans": [[start, end], ...]} with code point
offsets of every postal address: its unit and building lines, street,
locality, postcode and country, as one unit. The person or company it is
for, labels like "Ship to:" and the phone and email lines around it are not
part of it.

Addresses are made from real localities and street words with random
numbers (see addresses.py), set inside signatures, letters, prose, forms,
chat, and pasted JSON, CSV, XML, YAML and logs, beside hard negatives:
version strings, order and ticket numbers, times, quantities, code, tables
and man pages.

    python generate.py --count 100000 --seed 17 > train.0.jsonl
    python generate.py --count 5000 --seed 223 --holdout > test.jsonl
"""
import argparse
import json
import os
import random
import string
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from addresses import Addresses, digits, letters  # noqa: E402
from places import GB_WORDS  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
MAN = os.environ.get("ADDRESS_MAN", os.path.join(HERE, "data", "man.txt"))


class Doc:
    """Text built piece by piece, with the address spans it holds."""

    def __init__(self):
        self.parts, self.spans, self.length = [], [], 0

    def add(self, text):
        self.parts.append(text)
        self.length += len(text)
        return self

    def address(self, text):
        # The span never starts or ends on whitespace.
        stripped = text.strip()
        lead = len(text) - len(text.lstrip())
        if stripped:
            self.spans.append([self.length + lead, self.length + lead + len(stripped)])
        return self.add(text)

    @property
    def text(self):
        return "".join(self.parts)


COMPANIES = ["Northwind", "Corvane", "Tallowmere", "Bramblecote", "Quillfeather", "Harrowgate", "Lindqvist", "Okapi", "Brightwater", "Fennel & Rye",
             "Kestrel", "Marlowe", "Juniper", "Halcyon", "Vantor", "Ostrander", "Pellucid", "Sablewood", "Thistledown", "Wrenfield", "Ardent", "Calloway"]
SUFFIXES = ["Ltd", "Ltd.", "Inc.", "LLC", "GmbH", "S.A.", "B.V.", "Pty Ltd", "AB", "Oy", "S.r.l.", "SAS", "plc", "Co.", "Group", "Partners", "Labs", "Holdings", "Consulting"]
TITLES = ["Account Manager", "Office Manager", "Head of Operations", "Customer Success Lead", "Senior Paralegal", "Director of Finance", "Software Engineer",
          "Practice Manager", "Logistics Coordinator", "Sales Director", "Claims Handler", "HR Business Partner", "Procurement Officer", "Chief of Staff",
          "Registered Nurse", "Solicitor", "Property Manager", "Project Lead", "Founder & CEO", "Accounts Payable"]
CLOSINGS = ["Best,", "Best regards,", "Kind regards,", "Regards,", "Thanks,", "Thank you,", "Cheers,", "Sincerely,", "Warm regards,", "Many thanks,",
            "Yours sincerely,", "Mit freundlichen Grüßen", "Cordialement,", "Saludos,", "Met vriendelijke groet,", "Cordiali saluti,", "Med vänliga hälsningar,", "—", "--"]
GREETINGS = ["Hi {f},", "Hello {f},", "Dear {f},", "Dear Mr {l},", "Dear Ms {l},", "Hey {f},", "Good morning {f},", "Hi team,", "Hello,", "Dear Sir or Madam,"]
LABELS = ["Address:", "Mailing address:", "Ship to:", "Shipping address:", "Billing address:", "Deliver to:", "Delivery address:", "Correspondence address:",
          "Home address:", "Registered office:", "Postal address:", "Return address:", "Send to:", "Location:", "Office:", "HQ:", "Bill to:", "Sold to:",
          "Adresse:", "Anschrift:", "Dirección:", "Indirizzo:", "Adres:", "Morada:", "Current address:", "New address:", "Previous address:", "Venue:"]
PROSE_BEFORE = [
    "Please send the signed copy to {a}.", "Could you post the documents to {a}?", "I have moved to {a}, so please update my records.",
    "My new address is {a}.", "Our office is at {a}.", "The parcel was delivered to {a} instead of my flat.", "We're now based at {a}.",
    "You can return the item to {a}.", "Invoices should go to {a} from next month.", "She lives at {a} with her two kids.",
    "The tenant at {a} reported the leak on Monday.", "He gave his address as {a} when he signed up.", "Correspondence should be addressed to {a}.",
    "The meeting will be held at {a}.", "Please update the shipping address to {a}.", "the courier left it at {a} but nobody was home",
    "Forward any mail to {a} until further notice.", "The property at {a} was sold in March.", "I'm staying at {a} until the 14th.",
    "Swing by {a} after 6 and I'll hand you the keys.", "Pickup is from {a}, rear entrance.", "Registered address: {a}.", "they relocated to {a} last year",
    "The applicant resides at {a}.", "Deliveries for the event go to {a}.", "The cheque was sent to {a} on 3 May.", "can you change it to {a} pls",
    "Address on file: {a}", "Billing is still going to {a}, which is my old place.", "We met at her place, {a}, around noon.",
    "Witness statement taken at {a}.", "Please collect from {a} between 9 and 5.", "The new clinic opens at {a} in September.",
    "Wohnhaft in {a}.", "Merci d'envoyer le colis à {a}.", "Mi dirección es {a}.", "Il mio indirizzo è {a}.", "Mijn adres is {a}.",
]
STREET_PROSE = [
    "I live at {a} now.", "Meet me outside {a} at 7.", "the house at {a} has been empty for months", "She grew up on {a} in the nineties.",
    "Drop it at {a}, the blue door.", "We're renting a flat at {a} for the summer.", "His studio is at {a}, upstairs.", "Leak reported at {a} this morning.",
    "they bought the place at {a} last spring", "Parking is behind {a}.", "Noise complaint about {a} again.", "He moved into {a} in {city}.",
    "My parents still live at {a} in {city}.", "The shop at {a}, {city}, closes at five.", "We moved to {a} near the station.",
]
LEADS = ["the sale of", "they bought", "the courier tried", "we visited", "the flat at", "parcel left at", "the keys for", "inspection booked at", "boiler service at",
         "she still owns", "my mum's place at", "the old house at", "our new place is", "address is", "his office at", "the clinic at", "drop-off at",
         "we stayed at", "rent for", "council tax for", "the lease on", "a viewing at", "the alarm at", "the survey of", "the landlord of", "please invoice",
         "I'm at", "now living at", "send post to", "deliver to", "registered at", "the shop at", "meet at", "it's", "find us at", "he's moving to",
         "new address will be", "the address will be", "it will be", "the new one is", "she said it's", "the office is now", "we are now at",
         "the fire was reported at", "police attended", "the incident at", "a parcel for", "the meter at", "we're based at", "nous sommes au",
         "nos bureaux sont au", "siamo al", "wir sind in der", "unsere Adresse:", "estamos en", "la oficina está en", "we zitten aan de", "vi finns på",
         "mieszkam przy", "moramos na", "the van couldn't find", "can you post it to", "pls ship to", "forward it to", "the survey for"]
TAILS = ["", ".", "!", "?", " thx", " ty", " pls", " asap", " is on the market.", " settled on Friday.", " twice but no one was in.", " last week.",
         " on Monday.", " before 5pm.", " — I moved last month.", " (the blue door).", ", which is closer to work.", " and it's still empty.",
         " since 2019.", " until further notice.", " if that's easier.", " tomorrow morning.", " for the next three weeks.", " but the gate code changed.",
         " is now under offer.", " has a new tenant.", " and the bins go out on Tuesday.", " instead.", " - cheers", " :)", " next to the pharmacy.",
         " opposite the station.", " is where the boxes are.", " was flooded in March.", " needs a new boiler.", " and ask for reception.",
         " shortly after midnight.", " after 4pm", " after six", " from Monday", " so it went back to the depot.", " but the buzzer is broken",
         " for the long weekend.", " in July.", ", third floor.", ", second door on the left.", ", buzzer 4.", ", entrance B.", " until the 3rd.",
         " depuis lundi.", " à partir de demain.", " citofono 4.", " dal lunedì.", " ab Montag.", " seit Juli.", " desde el lunes.", " vanaf maandag.",
         " från och med måndag.", " od poniedziałku.", " a partir de segunda.", " (back entrance)", " — ring twice", " thanks", " ta", " cheers"]
INTROS = ["", "", "", "FYI ", "Update: ", "Re your question: ", "As discussed, ", "Quick one: ", "Hi, ", "Note: "]
AFTER = ["", "", "", " Thanks!", " Let me know if that works.", " The code for the gate is 4471.", " Call me on arrival.", " Ring the bell twice.",
         " It should arrive by Friday.", " Ref: INV-20931.", " See you then.", " Order 55120 is on hold until then."]


class Generator:
    def __init__(self, seed, holdout=False):
        self.rng = random.Random(seed)
        self.a = Addresses(self.rng, holdout)
        self.man = [p for p in open(MAN, encoding="utf-8").read().split("\n\n") if p.strip()] if os.path.exists(MAN) else []

    def pick(self, seq):
        return self.rng.choice(seq)

    def chance(self, p):
        return self.rng.random() < p

    # -- small parts
    def first(self):
        return self.pick(self.a.first)

    def last(self):
        return self.pick(self.a.last)

    def person(self):
        f, l = self.first(), self.last()
        return self.pick([f"{f} {l}", f"{f} {l}", f"{f} {self.pick(string.ascii_uppercase)}. {l}", f"Dr {f} {l}", f"{f} {l}, PhD", f"{l.upper()} {f}"])

    def company(self):
        return f"{self.pick(COMPANIES)} {self.pick(SUFFIXES)}"

    def phone(self):
        return self.pick([f"+1 ({self.rng.randint(201, 989)}) 555-{self.rng.randint(100, 199):04d}", f"+44 {self.rng.randint(20, 1999)} {digits(self.rng, 3)} {digits(self.rng, 4)}",
                          f"({self.rng.randint(201, 989)}) {self.rng.randint(200, 999)}-{digits(self.rng, 4)}", f"+49 {self.rng.randint(30, 999)} {digits(self.rng, 7)}",
                          f"+33 {self.rng.randint(1, 9)} {digits(self.rng, 2)} {digits(self.rng, 2)} {digits(self.rng, 2)} {digits(self.rng, 2)}",
                          f"0{self.rng.randint(2, 9)} {digits(self.rng, 4)} {digits(self.rng, 4)}", f"{self.rng.randint(201, 989)}.{self.rng.randint(200, 999)}.{digits(self.rng, 4)}",
                          f"+61 {self.rng.randint(2, 8)} {digits(self.rng, 4)} {digits(self.rng, 4)}", f"x{digits(self.rng, 5)}"])

    def email(self, f=None, l=None):
        f, l = (f or self.first()).lower(), (l or self.last()).lower()
        return f"{f}.{l}@{self.pick(COMPANIES).lower().replace(' ', '').replace('&', '')}.{self.pick(['com', 'co.uk', 'de', 'io', 'test', 'example'])}"

    def url(self):
        return f"{self.pick(['www.', 'https://', 'https://www.', ''])}{self.pick(COMPANIES).lower().replace(' ', '').replace('&', '')}.{self.pick(['com', 'co.uk', 'eu', 'io'])}{self.pick(['', '/contact', '/careers'])}"

    def address_text(self, kind=None, one=None):
        for _ in range(20):
            address = self.a.make()
            if kind is None or address.kind in kind:
                break
        one = self.chance(0.45) if one is None else one
        return (address.one(self.rng) if one else address.multi(self.rng)), address

    # -- documents with addresses
    def signature(self, doc):
        f, l = self.first(), self.last()
        if self.chance(0.6):
            doc.add(self.pick(["Thanks for the quick turnaround.", "See attached.", "Let me know if you need anything else.", "Speak soon.", "Happy to jump on a call."]) + "\n\n")
        doc.add(self.pick(CLOSINGS) + "\n" + self.pick([f"{f} {l}", f, f"{f} {l}", f"{f[0]}. {l}"]) + "\n")
        if self.chance(0.6):
            doc.add(self.pick(TITLES) + ("\n" if self.chance(0.7) else " | "))
        if self.chance(0.6):
            doc.add(self.company() + "\n")
        text, _ = self.address_text(one=self.chance(0.25))
        style = self.rng.random()
        if style < 0.12:
            # One line, items split by pipes or bullets.
            sep = self.pick([" | ", " · ", " • ", " / ", " – "])
            doc.add(self.company() + sep).address(text.replace("\n", ", ")).add(sep + self.phone() + "\n")
        else:
            indent = self.pick(["", "", "", "  ", "\t"])
            if indent:
                doc.address(indent + text.replace("\n", "\n" + indent))
            else:
                doc.address(text)
            doc.add("\n")
        lines = [self.pick(["T: ", "Tel: ", "Phone: ", "M: ", "Mob: ", "Direct: ", "", "Office: "]) + self.phone(), self.email(f, l), self.url(),
                 self.pick(["Fax: ", "F: "]) + self.phone(), f"{self.pick(['Pronouns', 'Pronoun'])}: {self.pick(['she/her', 'he/him', 'they/them'])}"]
        self.rng.shuffle(lines)
        for line in lines[:self.rng.randint(0, 3)]:
            doc.add(line + "\n")
        if self.chance(0.2):
            doc.add(self.pick(["\nThis e-mail and any attachments are confidential and intended solely for the addressee.",
                               "\nRegistered in England and Wales, company number " + digits(self.rng, 8) + ".",
                               "\nPlease consider the environment before printing this email.",
                               "\nSent from my iPhone", "\nVAT No. GB " + digits(self.rng, 9)]))

    def letter(self, doc):
        sender, _ = self.address_text(one=False)
        if self.chance(0.6):
            doc.add(self.person() + "\n").address(sender).add("\n\n")
        doc.add(self.pick(["12 March 2024", "March 12, 2024", "2024-03-12", "12/03/2024", "Friday, 4 October", "Paris, le 3 mai 2024", "4 Oct 2023"]) + "\n\n")
        if self.chance(0.8):
            doc.add(self.pick(["", "", "Attn: ", "FAO ", "Private & Confidential\n", "c/o "]) + self.person() + "\n")
        if self.chance(0.3):
            doc.add(self.company() + "\n")
        text, _ = self.address_text(one=False)
        doc.address(text).add("\n\n")
        if self.chance(0.4):
            doc.add(self.pick(["Re: ", "Subject: ", "Our ref: ", "Your ref: ", "Account no. "]) + self.pick(["Policy " + digits(self.rng, 8), "Tenancy renewal", "Invoice " + digits(self.rng, 5), "Claim " + letters(self.rng, 3) + digits(self.rng, 6), digits(self.rng, 9)]) + "\n\n")
        doc.add(self.pick(GREETINGS).format(f=self.first(), l=self.last()) + "\n\n")
        doc.add(self.pick(["Thank you for your letter of 2 May.", "I am writing to confirm your tenancy.", "Further to our call today, please find enclosed the forms.",
                           "We have received your payment of £240.00.", "Your appointment is on 14 June at 10:30."]))

    def prose(self, doc):
        doc.add(self.pick(INTROS))
        if self.chance(0.35):
            # A lead-in and a tail of ordinary words, so the address ends where the words do.
            text, _ = self.address_text(kind=None if self.chance(0.6) else ("street",), one=True)
            lead = self.pick(LEADS)
            if self.chance(0.5):
                lead = lead[0].upper() + lead[1:]
            doc.add(lead + " ").address(text).add(self.pick(TAILS))
        elif self.chance(0.3):
            text, address = self.address_text(kind=("street",), one=True)
            city = self.pick(self.a.loc[address.country]).place
            template = self.pick(STREET_PROSE)
            before, after = template.split("{a}")
            doc.add(before).address(text).add(after.replace("{city}", city))
        else:
            text, _ = self.address_text(one=self.chance(0.85))
            before, after = self.pick(PROSE_BEFORE).split("{a}")
            doc.add(before).address(text).add(after)
        doc.add(self.pick(AFTER))
        if self.chance(0.3):
            doc.add("\n\n" + self.pick(CLOSINGS) + "\n" + self.first())

    def form(self, doc):
        label = self.pick(LABELS)
        text, _ = self.address_text()
        name = self.person() if self.chance(0.5) else None
        if self.chance(0.5):
            doc.add(label + "\n")
            if name:
                doc.add(name + "\n")
            doc.address(text.replace(", ", "\n") if self.chance(0.3) else text)
        else:
            doc.add(label + self.pick([" ", "  ", "\t"]))
            if name:
                doc.add(name + ", ")
            doc.address(text.replace("\n", ", "))
        doc.add("\n")
        for line in self.rng.sample([f"Phone: {self.phone()}", f"Email: {self.email()}", f"Order #: {digits(self.rng, 6)}", f"Delivery: {self.pick(['Standard', 'Express', 'Next day'])}",
                                     f"Qty: {self.rng.randint(1, 12)}", f"Total: ${self.rng.randint(5, 900)}.{digits(self.rng, 2)}", f"Notes: leave with neighbour at {self.rng.randint(2, 40)}"], self.rng.randint(0, 3)):
            doc.add(line + "\n")

    def chat(self, doc):
        lines = [f"[{self.rng.randint(8, 22)}:{self.rng.randint(0, 59):02d}] {self.first()}: " + self.pick(["what's the address?", "where do I send it", "omw", "running 10 min late", "which entrance?"])]
        text, _ = self.address_text(one=True)
        who = self.first()
        before = f"[{self.rng.randint(8, 22)}:{self.rng.randint(0, 59):02d}] {who}: " + self.pick(["", "it's ", "send to ", "address is ", "we're at ", "new place: "])
        for line in lines:
            doc.add(line + "\n")
        doc.add(before).address(text).add(self.pick(["", " 🙂", " (buzz 4B)", " thx", ", ring twice"]) + "\n")
        if self.chance(0.5):
            doc.add(f"[{self.rng.randint(8, 22)}:{self.rng.randint(0, 59):02d}] {self.first()}: " + self.pick(["got it", "👍", "see you at 7:30", "parcel #" + digits(self.rng, 6) + " shipped"]))

    def structured(self, doc):
        """Pasted JSON, CSV, XML, YAML or a log line, as plain text."""
        text, _ = self.address_text(one=self.chance(0.7))
        name, mail = self.person(), self.email()
        kind = self.rng.random()
        if kind < 0.3:
            escaped = text.replace("\n", "\\n")
            key = self.pick(["address", "mailing_address", "addr", "shipping", "location", "billing_address", "street_address", "notes", "comment", "remarks", "home"])
            lead, tail = (self.pick(LEADS) + " ", self.pick(TAILS).replace('"', "")) if key in ("notes", "comment", "remarks") and self.chance(0.7) else ("", "")
            doc.add("{\n  " + f'"id": {self.rng.randint(1000, 99999)},\n  "name": "{name}",\n  "email": "{mail}",\n  "{key}": "' + lead).address(escaped)
            doc.add(tail + '",\n  "plan": "' + self.pick(["Team", "Pro", "Free"]) + f'",\n  "seats": {self.rng.randint(1, 40)}\n' + "}")
        elif kind < 0.55:
            one = text.replace("\n", ", ")
            doc.add(f"id,name,email,address,joined\n{self.rng.randint(1, 999)},{name},{mail},\"").address(one).add(f"\",2023-{self.rng.randint(1, 12):02d}-{self.rng.randint(1, 28):02d}\n")
            other, _ = self.address_text(one=True)
            doc.add(f"{self.rng.randint(1, 999)},{self.person()},{self.email()},\"").address(other.replace("\n", ", ")).add(f"\",2024-0{self.rng.randint(1, 9)}-1{self.rng.randint(0, 9)}")
        elif kind < 0.7:
            doc.add(f"<customer id=\"{self.rng.randint(1, 9999)}\">\n  <name>{name}</name>\n  <{self.pick(['address', 'street', 'addr', 'postal'])}>").address(text.replace("\n", ", "))
            doc.add(f"</{self.pick(['address'])}>\n  <phone>{self.phone()}</phone>\n</customer>")
        elif kind < 0.85:
            doc.add(f"customer:\n  name: {name}\n  address: ").address(text.replace("\n", ", ")).add(f"\n  tier: {self.pick(['gold', 'silver'])}\n  since: 2021")
        else:
            doc.add(f"2024-0{self.rng.randint(1, 9)}-1{self.rng.randint(0, 9)}T1{self.rng.randint(0, 9)}:{self.rng.randint(10, 59)}:0{self.rng.randint(0, 9)}Z INFO shipment created order={digits(self.rng, 6)} to=\"").address(text.replace("\n", ", ")).add(f"\" carrier={self.pick(['ups', 'dhl', 'royalmail'])}")

    def several(self, doc):
        """A list of addresses, each one its own unit."""
        doc.add(self.pick(["Branches:", "Our offices", "Locations", "Previous addresses:", "Stores near you:", "Pickup points"]) + "\n")
        for _ in range(self.rng.randint(2, 4)):
            text, _ = self.address_text(one=self.chance(0.6))
            bullet = self.pick(["- ", "* ", "• ", "", f"{self.pick(['London', 'Head office', 'Warehouse', 'Depot', 'Store'])}: "])
            doc.add(bullet).address(text).add("\n" + ("\n" if "\n" in text or self.chance(0.3) else ""))

    # -- hard negatives (no address)
    def version(self):
        return self.pick([f"v{self.rng.randint(0, 20)}.{self.rng.randint(0, 30)}.{self.rng.randint(0, 99)}", f"Python {self.rng.randint(2, 3)}.{self.rng.randint(6, 13)}.{self.rng.randint(0, 20)}",
                          f"macOS {self.rng.randint(10, 26)}.{self.rng.randint(0, 6)} (Build {self.rng.randint(19, 25)}{self.pick('ABCDEFG')}{self.rng.randint(10, 999)})",
                          f"Release {self.rng.randint(1, 9)}.{self.rng.randint(0, 9)} Long Term Support", f"Node {self.rng.randint(14, 24)}.x LTS", f"iOS {self.rng.randint(12, 19)}.{self.rng.randint(0, 4)}",
                          f"Version {self.rng.randint(1, 12)}.{self.rng.randint(0, 9)} Street Edition", f"Chrome/{self.rng.randint(90, 140)}.0.{digits(self.rng, 4)}.{digits(self.rng, 2)} Safari/537.36",
                          f"PostgreSQL {self.rng.randint(9, 17)}.{self.rng.randint(0, 9)} on x86_64", f"build {digits(self.rng, 5)} Main Branch", f"Windows 11 Pro 23H2"])

    def reference(self):
        n = digits(self.rng, self.rng.randint(4, 8))
        return self.pick([f"order {n}", f"Order #{n}", f"Invoice #{n}", f"ticket {n}", f"Ticket #{n} Priority High", f"case no. {n}", f"Ref: {n}",
                          f"PO {n} Main Warehouse", f"booking {letters(self.rng, 2)}{n}", f"Tracking {letters(self.rng, 2)}{n}GB", f"claim {n} Court Street Division" if self.chance(0.1) else f"claim {n}",
                          f"Policy {n}", f"Receipt {n}", f"Confirmation {letters(self.rng, 6)}", f"Account {n}", f"Room {self.rng.randint(1, 900)} Building {self.pick('ABCDEF')}",
                          f"Gate B{self.rng.randint(1, 40)}", f"Platform {self.rng.randint(1, 20)}", f"Flight {letters(self.rng, 2)} {self.rng.randint(10, 999)} to {self.pick(['London', 'Boston', 'Lyon', 'Perth'])}",
                          f"Route {self.rng.randint(1, 99)}", f"Highway {self.rng.randint(1, 99)} closed", f"Bus {self.rng.randint(1, 300)} to {self.pick(['Union Square', 'Market Street', 'King Street', 'the Park'])}",
                          f"Chapter {self.rng.randint(1, 30)} Section {self.rng.randint(1, 12)}", f"Article {self.rng.randint(1, 60)} of the Convention", f"Section {self.rng.randint(1, 400)} Companies Act {self.rng.randint(1985, 2020)}",
                          f"Rule {self.rng.randint(1, 80)}(b)({self.rng.randint(1, 9)})", f"Application no. {self.rng.randint(1000, 99999)}/{self.rng.randint(90, 99)}"])

    def quantity(self):
        n = self.rng.randint(1, 500)
        return self.pick([f"{n} Large Boxes", f"{n} Main Course Dishes", f"{n} Queen Beds", f"{n} King Size Pillows", f"{n} Park Benches", f"{n} Court Cases",
                          f"{n} Square Meals", f"{n} Way Splitter", f"{n} Lane Highway", f"{n} Drive Bays", f"{n} Place Settings", f"{n} Street Lamps",
                          f"{n} Avenue Trees", f"{n} Road Cones", f"{n} Terrace Chairs", f"{n} Close Calls", f"{n} kg", f"{n} x Widget Pro", f"{n} units of Model {letters(self.rng, 1)}{self.rng.randint(1, 9)}",
                          f"{n}% Off Spring Sale", f"{n} Days Left", f"{n} New Messages", f"{n} Hill Climbs", f"{n} Mile Run", f"{n} Green Tea Bags",
                          f"{self.rng.randint(1, 12)}:{self.rng.randint(0, 59):02d} {self.pick(['AM', 'PM', 'am', 'pm'])} {self.pick(['EST', 'PST', 'GMT', 'CET', ''])}",
                          f"{self.rng.randint(1, 28)} {self.pick(['May', 'March', 'June', 'October'])} {self.rng.randint(1990, 2026)}", f"Q{self.rng.randint(1, 4)} {self.rng.randint(2019, 2026)} Revenue {self.rng.randint(1, 999)},{digits(self.rng, 3)}",
                          f"{self.rng.randint(1, 31)} {self.pick(['May', 'June'])} Street Festival", f"Studio {self.rng.randint(1, 99)}", f"Apollo {self.rng.randint(7, 17)}", f"Model {self.rng.randint(3, 9)} Long Range"])

    def title_case_numbers(self):
        """Capitalised words beside numbers that are no address: dated sentences,
        numbered lists of companies, product titles, episodes, social posts."""
        month = self.pick(["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"])
        org = " ".join(self.pick(["Regional", "Remand", "Centre", "Board", "Legal", "Aid", "Assize", "Court", "Commission", "Green", "Land", "Development",
                                   "Power", "Cogeneration", "Energy", "Holdings", "Penitentiary", "Appeals", "Tribunal", "Council", "District", "Supreme",
                                   "Federal", "National", "Water", "Gas", "Transmission", "Pipeline", "Services", "Trust"]) for _ in range(self.rng.randint(2, 4)))
        place = self.pick(self.a.loc[self.pick(self.a.countries)]).place
        brand = self.pick(["Philips", "Nike", "Sony", "Aurora", "Canon", "Lenovo", "Bosch", "Dyson", "Garmin", "Logitech", "Samsung", "Apple"])
        handle = "@" + self.first() + self.pick(["", "_", "x"]) + str(self.rng.randint(1, 99))
        n = self.rng.randint(1, 99)
        return self.pick([
            f"On {self.rng.randint(1, 28)} {month} {self.rng.randint(1985, 2024)} the {place} {org} reviewed the decision.",
            f"On {self.rng.randint(1, 28)} {month} {self.rng.randint(1985, 2024)} the {org} notified the applicant's solicitors.",
            f"The case was resumed before the {self.rng.randint(1, 12)}th {org} of {place}.",
            "\n".join(f"{i}. {self.pick(COMPANIES)} {self.pick(['Green', 'West Fork', 'Land', 'Power', 'Cogeneration', 'Energy'])} {self.pick(['Development', 'I', 'II', 'Partners', 'Storage'])}, {self.pick(['LLC', 'L.P.', 'Inc.'])};" for i in range(1, self.rng.randint(3, 6))),
            f"#{n}: {brand} {letters(self.rng, 3)} {self.rng.randint(100, 999)} / {self.rng.randint(1, 99):02d} {self.pick(['Microwave Steriliser', 'Running Shoe', 'Smart Watch', 'Desk Lamp'])} http://t.co/{letters(self.rng, 10, string.ascii_letters)}",
            f"#Good New #{brand} Air {self.rng.randint(1, 13)} XI #Retro Low Cherry Varsity Red 100% Authentic Size {self.rng.randint(5, 13)}",
            f"The Affair Season {self.rng.randint(1, 9)} Episode {self.rng.randint(1, 22)} {self.pick(['Recap', 'Review', 'Promo'])} - {self.pick(['French', 'Spanish'])} translation",
            f"Book {self.rng.randint(1, 9)} in the #{self.pick(COMPANIES)}Realty series by {self.first()} {self.last()} {handle}",
            f"Top {self.rng.randint(3, 20)} Highest Paid Actors of {self.rng.randint(2010, 2024)} {handle} #{self.pick(['blog', 'travel', 'news'])}",
            f"{handle} {self.rng.randint(1, 99)} {handle} {self.rng.randint(1, 9)} hbk {self.pick(['#twug', '#ff', '#mood'])}",
            f"{place}- {self.pick(['Incheon', 'Kowloon', 'Shibuya'])}, {self.pick(['South Korea', 'Hong Kong', 'Japan'])}: Old Meets New Part {self.rng.randint(1, 9)} #blog https://t.co/{letters(self.rng, 10, string.ascii_letters)}",
            f"Listening to \"{self.rng.randint(1, 99)} Hr Network Radio\" on {handle} http://t.co/{letters(self.rng, 8, string.ascii_letters)}",
            f"How's {self.rng.randint(7, 11)} AM PDT, {self.rng.randint(10, 12)} AM EDT? Could you summarize the {self.rng.randint(1, 9)} Open Items first",
            f"{brand} {self.rng.randint(10, 99)} - {self.rng.randint(60, 120)} W / VA Dimmable Low Voltage Electronic Transformer",
            f"Mobile {self.pick(['Mammography', 'Blood Donor', 'Library'])} van will be at {self.pick(COMPANIES)} {month} {self.rng.randint(1, 20)}-{self.rng.randint(21, 28)}, {self.rng.randint(2000, 2024)}, from {self.rng.randint(7, 9)} a.m. - {self.rng.randint(3, 6)} p.m.",
            f"Tickets go on sale {self.pick(['Tuesday', 'Friday'])} {month} {self.rng.randint(1, 28)}th at EB{self.rng.randint(1000, 4000)}{self.pick(['a', 'b', ''])} ({self.first()} {self.last()}).",
            f"Five new {self.pick(['EWGs', 'QFs', 'sites'])} should be added to the {self.rng.randint(1998, 2024)} {letters(self.rng, 1)}{self.rng.randint(1, 9)}{letters(self.rng, 1)}{self.rng.randint(1, 9)} filing.",
            f"WPA{self.rng.randint(1, 3)} for WPA{self.rng.randint(1, 3)} Personal, WPA{self.rng.randint(1, 3)}E for WPA{self.rng.randint(1, 3)} Enterprise",
            f"Upload files to Amazon S{self.rng.randint(2, 3)} from {brand} Cloud {self.rng.randint(1, 5)} Pro?",
            f"Flight MH{self.rng.randint(1, 999)} from {place} to {self.pick(['London', 'Kuala Lumpur', 'Sydney'])} landed at {self.rng.randint(1, 12)}:{self.rng.randint(10, 59)} Local Time",
            f"Phase {self.rng.randint(1, 4)} of the {place} {org} project starts in {month}.",
            f"Unit {self.rng.randint(1, 9)} at the {place} Power Station tripped at {self.rng.randint(1, 12)}:{self.rng.randint(10, 59)}.",
            f"{self.rng.randint(1, 30)} {self.pick(['Wonders', 'Reasons', 'Ways', 'Things'])} Of The {self.pick(['World', 'Year', 'Week'])} - http://t.co/{letters(self.rng, 10, string.ascii_letters)}",
            f"Chapter {self.rng.randint(1, 30)}: The {self.pick(GB_WORDS)} {self.pick(['Road', 'Street', 'House'])} Murders",
            f"Tickets: Gate {letters(self.rng, 1)}{self.rng.randint(1, 40)}, Row {self.rng.randint(1, 40)}, Seat {self.rng.randint(1, 40)}.",
            f"Block {self.rng.randint(1, 30)}, Row {letters(self.rng, 1)}, Seats {self.rng.randint(1, 30)}-{self.rng.randint(31, 40)}, {self.pick(['North', 'East', 'Upper'])} Stand",
            f"Sprint {self.rng.randint(1, 40)} Planning — {self.rng.randint(2, 6)} Main Goals, {self.rng.randint(3, 21)} Story Points each.",
            f"Level {self.rng.randint(1, 60)} Boss Fight, {self.rng.randint(2, 9)} Lives Left, {self.rng.randint(100, 9999)} Gold Coins",
            f"Step {self.rng.randint(1, 9)}: Open Settings, {self.rng.randint(1, 9)} General Tabs, then Reboot",
            f"Week {self.rng.randint(1, 52)}, Day {self.rng.randint(1, 7)}: {self.rng.randint(3, 30)} Push Ups, {self.rng.randint(1, 10)} Mile Run",
            f"Lot {self.rng.randint(1, 400)}, Item {self.rng.randint(1, 99)}: Victorian Oak Chest, {self.rng.randint(2, 6)} Drawers",
            f"Exit {self.rng.randint(1, 99)}, Junction {self.rng.randint(1, 40)}, {self.rng.randint(2, 20)} Miles to {place}",
        ])

    def negative_line(self):
        r = self.rng.random()
        if r < 0.25:
            return self.reference()
        if r < 0.45:
            return self.quantity()
        if r < 0.6:
            return self.version()
        return self.pick([f"Tel: {self.phone()}", f"IBAN DE{digits(self.rng, 2)} {digits(self.rng, 4)} {digits(self.rng, 4)} {digits(self.rng, 4)} {digits(self.rng, 4)} {digits(self.rng, 2)}",
                          f"Card ending {digits(self.rng, 4)}", f"Lat {self.rng.uniform(-60, 60):.4f}, Lng {self.rng.uniform(-170, 170):.4f}", f"Score: {self.pick(COMPANIES)} {self.rng.randint(0, 5)} {self.pick(COMPANIES)} {self.rng.randint(0, 5)}",
                          f"{self.rng.randint(1, 31)}/{self.rng.randint(1, 12)}/{self.rng.randint(2000, 2030)} {self.rng.randint(0, 23)}:{self.rng.randint(0, 59):02d}", f"Total {self.rng.randint(1, 9999)}.{digits(self.rng, 2)} EUR",
                          f"Meeting at {self.rng.randint(8, 18)}:{self.pick(['00', '15', '30', '45'])} in Room {self.rng.randint(1, 40)}{self.pick(['', 'B'])}", f"Population {self.rng.randint(1, 999)},{digits(self.rng, 3)} (2021 Census)",
                          f"{self.pick(GB_WORDS)} {self.pick(['Road', 'Street', 'Lane'])} is closed for roadworks until {self.rng.randint(1, 28)} June.",
                          f"Delivered {self.rng.randint(2, 40)} parcels to the {self.pick(GB_WORDS)} Street depot", f"SKU {letters(self.rng, 3)}-{digits(self.rng, 5)} Blue Large",
                          f"Floor {self.rng.randint(1, 30)} kitchen is out of milk", f"See page {self.rng.randint(1, 400)}, paragraph {self.rng.randint(1, 40)}."])

    def code(self):
        n = self.rng.randint(1, 4096)
        return self.pick([
            f"for i in range({n}):\n    street = streets[i]\n    print(street.name, street.number)",
            f"int main(int argc, char **argv) {{\n    char buf[{n}];\n    return parse_address(buf, {self.rng.randint(1, 9)});\n}}",
            f"#define MAX_ROUTE {n}\n#define MAIN_STREET {self.rng.randint(1, 99)}",
            f"const address = {{ street: req.body.street, city: req.body.city, zip: req.body.zip }};\nawait db.save(address, {{ timeout: {n} }});",
            f"SELECT street, city, postcode FROM addresses WHERE id = {n} LIMIT {self.rng.randint(1, 50)};",
            f"margin: {self.rng.randint(0, 40)}px {self.rng.randint(0, 40)}px;\nfont: {self.rng.randint(10, 20)}px/1.4 Helvetica Neue, sans-serif;",
            f"git commit -m \"Fix Main Street layout on {self.rng.randint(2, 30)} column grid\"\n[main {digits(self.rng, 7)}] Fix layout\n {self.rng.randint(1, 9)} files changed, {self.rng.randint(1, 300)} insertions(+)",
            f"docker run -p {self.rng.randint(1000, 9999)}:{self.rng.randint(80, 9000)} -v /srv/data:/data app:{self.rng.randint(1, 9)}.{self.rng.randint(0, 9)}",
            f"Traceback (most recent call last):\n  File \"/app/geo/address.py\", line {self.rng.randint(1, 900)}, in normalise\n    return Street(parts[{self.rng.randint(0, 3)}])\nIndexError: list index out of range",
            f"  PID USER      PR  NI    VIRT    RES\n {self.rng.randint(100, 99999)} root      20   0  {self.rng.randint(1000, 999999)}  {self.rng.randint(100, 99999)}",
            f"class Address(Model):\n    line1 = CharField(max_length={self.rng.randint(32, 255)})\n    postcode = CharField(max_length={self.rng.randint(8, 12)})",
            f"$ curl -s https://api.example.com/v{self.rng.randint(1, 3)}/orders/{n} | jq .status\n\"shipped\"",
        ])

    def table(self):
        rows = [self.pick(["| Item | Qty | Price |", "Region,Q1,Q2,Q3,Q4", "Name        Size  Modified", "Route  Stops  Minutes", "Rank Team Played Won Points"])]
        for _ in range(self.rng.randint(2, 6)):
            rows.append(self.pick([f"| {self.pick(['Main Course', 'Park Pass', 'Court Fee', 'Lane Rental', 'Street Map'])} | {self.rng.randint(1, 40)} | {self.rng.randint(1, 300)}.{digits(self.rng, 2)} |",
                                   f"{self.pick(['North', 'South', 'East', 'West', 'Central'])},{self.rng.randint(1, 999)},{self.rng.randint(1, 999)},{self.rng.randint(1, 999)},{self.rng.randint(1, 999)}",
                                   f"{self.pick(['report', 'Main', 'Park'])}_{self.rng.randint(1, 99)}.pdf  {self.rng.randint(1, 900)}K  {self.rng.randint(1, 28)} {self.pick(['Mar', 'Apr', 'Jun'])} {self.rng.randint(10, 23)}:{self.rng.randint(10, 59)}",
                                   f"{self.rng.randint(1, 99)}  {self.pick(['Victoria Line', 'Park Road loop', 'High Street shuttle', 'Route 12A'])}  {self.rng.randint(2, 40)}  {self.rng.randint(5, 90)}",
                                   f"{self.rng.randint(1, 20)} {self.pick(COMPANIES)} {self.rng.randint(10, 38)} {self.rng.randint(0, 30)} {self.rng.randint(0, 90)}"]))
        return "\n".join(rows)

    def negative(self, doc):
        r = self.rng.random()
        if r < 0.3 and self.man:
            doc.add(self.pick(self.man))
        elif r < 0.45:
            doc.add(self.code())
        elif r < 0.55:
            doc.add(self.table())
        elif r < 0.66:
            lines = [self.title_case_numbers() for _ in range(self.rng.randint(1, 3))]
            doc.add(self.pick(["\n", "\n\n", " "]).join(lines))
        elif r < 0.73:
            # The greeting after a filed number is no state, and the number no ZIP.
            doc.add(self.pick(["re: ", "Re: ", "Subject: ", "", "Update on "]) + self.reference() + self.pick(["\n", "\n", " "]) + self.pick(GREETINGS).format(f=self.first(), l=self.last()) + "\n\n" + self.pick(
                ["Your replacement card has shipped.", "The courier has it now.", "We've issued a refund.", "Can you confirm the delivery date?"]))
        else:
            lines = [self.negative_line() for _ in range(self.rng.randint(1, 5))]
            doc.add(self.pick(["\n", ". ", "; ", "\n- "]).join(lines))

    def document(self):
        doc = Doc()
        r = self.rng.random()
        if r < 0.4:
            self.negative(doc)
            if self.chance(0.3):
                doc.add("\n\n")
                self.negative(doc)
            return doc
        if self.chance(0.2):
            self.negative(doc)
            doc.add(self.pick(["\n\n", "\n", " "]))
        maker = self.rng.choices([self.signature, self.letter, self.prose, self.form, self.chat, self.structured, self.several], [26, 8, 24, 12, 6, 14, 4])[0]
        maker(doc)
        if self.chance(0.25):
            doc.add(self.pick(["\n\n", "\n"]))
            self.negative(doc)
        return doc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--holdout", action="store_true", help="only the held-out localities, streets and names")
    args = parser.parse_args()
    sys.path.insert(0, HERE)
    from eval_lines import eval_grams, grams
    held = eval_grams()
    generator = Generator(args.seed, args.holdout)
    written = dropped = 0
    while written < args.count:
        doc = generator.document()
        text = doc.text
        if grams(text) & held:
            dropped += 1
            continue
        print(json.dumps({"text": text, "spans": doc.spans}, ensure_ascii=False))
        written += 1
    print(f"written={written} dropped={dropped}", file=sys.stderr)


if __name__ == "__main__":
    main()
