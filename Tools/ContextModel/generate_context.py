"""Labelled training text for the context model.

Labels: PERSON, USERNAME, LOCATION, ORG (an employer, only when tied to a
person), ID, SECRET, DOB. Builds on the name model's generate.py (names,
handles, chat, logs, key/value, man-page prose) and adds places, employers,
non-Latin names, IDs, secrets and birth dates with wording of its own. The
towns, organisations, non-Latin names and ID labels the benchmarks use are
held out on purpose.
"""
import argparse
import json
import os
import random
import string
import sys

# Names, handles, chat, logs, key/value and man-page prose come from the name model's generator.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "NameModel"))
import generate as g  # noqa: E402

TOWNS = ["Aarhus", "Bergen", "Tórshavn", "Gdańsk", "Łódź", "Brno", "Whitby", "Kendal", "Bude", "Ullapool", "Kilkenny", "Dingle", "Annecy",
         "Colmar", "Albi", "Cuenca", "Ronda", "Évora", "Tavira", "Lucca", "Spoleto", "Bamberg", "Görlitz", "Hallstatt", "Lugano", "Delft",
         "Leuven", "Ghent", "Tartu", "Kaunas", "Plovdiv", "Sibiu", "Mostar", "Kotor", "Ohrid", "Bergamo", "Trondheim", "Umeå", "Oulu",
         "Rovaniemi", "Akureyri", "Galway", "Sligo", "Wagga Wagga", "Bendigo", "Toowoomba", "Napier", "Nelson", "Timaru", "Rotorua",
         "Kumasi", "Tamale", "Mombasa", "Kisumu", "Arusha", "Moshi", "Gulu", "Mwanza", "Enugu", "Ibadan", "Jos", "Bamako", "Kano", "Fez",
         "Agadir", "Sfax", "Aswan", "Luxor", "Pune", "Mysore", "Udaipur", "Madurai", "Kochi", "Shillong", "Pokhara", "Kandy", "Galle",
         "Chiang Mai", "Hue", "Da Lat", "Ipoh", "Iloilo", "Cebu", "Davao", "Bandung", "Yogyakarta", "Medan", "Kanazawa", "Sendai",
         "Matsumoto", "Gyeongju", "Busan", "Daegu", "Tainan", "Hsinchu", "Guilin", "Lhasa", "Ulan-Ude", "Irkutsk", "Samarkand", "Bukhara",
         "Tabriz", "Shiraz", "Izmir", "Trabzon", "Batumi", "Gyumri", "Arequipa", "Cusco", "Salta", "Mendoza", "Valparaíso", "Puno",
         "Popayán", "Manizales", "Mérida", "Puebla", "Querétaro", "Antigua", "León", "Ouro Preto", "Recife", "Natal", "Florianópolis",
         "Asheville", "Bozeman", "Missoula", "Flagstaff", "Tulsa", "Duluth", "Burlington", "Bangor", "Moab", "Taos", "Nanaimo", "Kelowna",
         "Moncton", "Saskatoon", "Whitehorse", "Iqaluit", "Москва", "Новосибирск", "札幌", "福岡", "成都", "부산", "الإسكندرية", "חיפה",
         "Θεσσαλονίκη", "เชียงราย", "जयपुर"]
PLACE_CUES = ["relocated to {p}", "is based out of {p}", "her parents still live in {p}", "flying into {p} on Thursday",
              "spent ten years in {p}", "now lives just outside {p}", "his family is from {p}", "we met in {p}", "rents a flat in {p}",
              "drove up to {p} for the funeral", "transferred to the {p} branch", "was raised in {p}", "home address is in {p}",
              "staying with her sister in {p}", "registered to vote in {p}"]

ORG_HEADS = ["Silverbrook", "Ashcombe", "Kettering", "Marlbury", "Pennick", "Rowanlea", "Stonebridge", "Thistledown", "Wyncroft",
             "Larkspur", "Copperfield", "Elmstead", "Foxhollow", "Glenmoor", "Harrowgate", "Ivybridge", "Juniper", "Kingsley",
             "Linden", "Millbrook", "Northgate", "Orchard", "Pinecrest", "Redfern", "Saltmarsh", "Tidewater", "Underhill",
             "Valebrook", "Westholme", "Yarrow", "Bluebell", "Cedarline", "Driftwood", "Emberly", "Fairhaven", "Greystone"]
ORG_TAILS = ["Clinic", "Dental", "Pharmacy", "Logistics", "Freight", "Bakery", "Primary School", "Academy", "Hotel", "Inn", "Motors",
             "Garage", "Solicitors", "Accountants", "Care Home", "Medical Centre", "Veterinary Practice", "Library", "Council",
             "Hospital", "Studio", "Farm", "Brewery", "Café", "Construction", "Plumbing", "Electrical", "Insurance", "Credit Union",
             "Building Society", "Leisure Centre", "Nursery", "Surgery", "Warehouse", "Joinery", "Print Works"]
EMPLOYER_CUES = ["{w} works at {o}", "{w} is a {job} at {o}", "{w} has been with {o} for {n} years", "{w} just got a job at {o}",
                 "{w} has been employed by {o} since {y}", "{w}'s manager at {o} signed the letter", "{w} is currently at {o} as a {job}",
                 "{w} used to work at {o}", "{w} quit {o} in {m}", "{w} does weekend shifts for {o}", "{w} was made redundant by {o}",
                 "{w} started at {o} last {m}", "Employer: {o}", "Current employer - {o}", "{w} is on the payroll at {o}",
                 "{w} cleans for {o} three days a week", "{w} trained as a {job} with {o}"]
VENDOR_CUES = ["Invoice from {o} attached.", "{o} delivered the pallets this morning.", "We switched suppliers to {o}.",
               "{o} is closed on bank holidays.", "Quote received from {o}, valid 30 days.", "{o} replaced the boiler in unit 4.",
               "Booked the venue through {o}.", "{o} sent a revised price list.", "Paid {o} by bank transfer.",
               "The {o} van blocked the loading bay again.", "Review: {o} was quick and friendly."]
JOBS = ["nurse", "receptionist", "driver", "cook", "cleaner", "teacher", "pharmacist", "mechanic", "porter", "bookkeeper", "carer",
        "paralegal", "dental nurse", "night manager", "baker", "electrician", "librarian"]

ID_LABELS = ["passport no.", "passport number", "national ID", "ID card number", "driver's licence", "driving licence number",
             "license #", "SSN", "social security number", "tax file number", "TIN", "health card number", "insurance number",
             "Medicare number", "patient ID", "employee number", "staff ID", "badge number", "account number", "customer number",
             "loyalty number", "membership no.", "library card", "PPS number", "BSN", "personnummer", "NIE", "RUT", "codice fiscale",
             "residence permit number", "voter ID", "pension number", "benefits reference", "case reference"]
ID_TEMPLATES = ["my {l} is {v}", "{L}: {v}", "{l} {v}", "Can you update the {l} to {v}?", "{v} is the {l} we have on file",
                "{L} #{v}", "the caller gave {l} {v} to verify", "{L} = {v}", "her {l} ({v}) does not match", "confirm {l}: {v}?"]
ID_BARE = ["re-check record {v} before Friday", "{v} matched two people in the import", "duplicate: {v} appears in both files",
           "please anonymise {v} in the export", "{v} belongs to the caller from this morning"]
# A case, claim or file someone brought, cited by its number: the number is theirs.
REF_LABELS = ["application", "complaint", "claim", "appeal", "petition", "case file", "file", "dossier", "grievance", "request"]
REF_TEMPLATES = ["the {r} (no. {v}) was lodged last spring", "{w} lodged an {r} (no. {v}) against the council", "{R} no. {v} was joined to the others",
                 "in {r} No. {v} the panel found a breach", "under {r} no. {v}, the hearing is set for May", "her {r}, no. {v}, is still pending",
                 "{w} withdrew {r} no. {v}", "see the decision on {r} no. {v}", "{R} No. {v} ({w} v. the city) was struck out"]
# Numbers of laws, articles, protocols and rules: everyone's, no one's own.
NOT_REF = ["Article {r} § {s} of the Convention", "Protocol No. {s} to the treaty", "under Rule {r} of the rules of procedure",
           "Law no. {n} on public assemblies", "Regulation (EU) {y}/{k} applies", "Directive {y}/{r}/EC was transposed late",
           "Resolution {k}/{y} of the assembly", "section {r}({s}) of the Act", "paragraph {r} of the judgment", "Decree no. {n}/{y} was repealed"]
NOT_ID = ["order #{n}", "invoice INV-{y}-{s}", "ticket {n}", "build {n} passed", "version {a}.{b}.{c}", "port {p}", "PR #{n}",
          "request_id={h}", "room {r}", "flight BA{s}", "SKU {sku}", "page {r} of {n}", "{n} items in stock", "batch {y}-{s}",
          "tracking number {track}"]

PW_WORDS = ["harbor", "copper", "lantern", "orbit", "summit", "falcon", "pepper", "maple", "comet", "river", "tiger", "violet",
            "biscuit", "pickle", "rocket", "sunset", "thunder", "walnut", "zephyr", "kiwi"]
SECRET_TEMPLATES = ["the {t} password is {v}", "pw: {v}", "password={v}", "passcode {v}", "use {v} as the password",
                    "my password's {v} lol", "new password for {t}: {v}", "{t} login is admin / {v}", "the code to the safe is {pin}",
                    "PIN {pin}", "api key: {v}", "secret {v}", "Authorization: Bearer {tok}", "Authorization: Basic {b64}",
                    "https://{u}:{v}@{host}/repo", "{ENV}={tok}", "export {ENV}={tok}", "token={tok}", "the shared key is {hex}",
                    "client secret {tok}", "recovery code {rc}", "wifi: {v}"]
NOT_SECRET = ["commit {hex40} fixed it", "sha256 {hex64} matches the download", "request id {hex16}", "trace {uuid}",
              "the password reset link expired", "password field is required", "enter your PIN at the terminal",
              "rotate the API key every 90 days", "the token endpoint returned 401", "see secret management docs",
              "object {uuid} was deleted", "cache key {hex16} evicted"]
ENVS = ["API_KEY", "DB_PASSWORD", "SECRET_KEY", "AUTH_TOKEN", "SMTP_PASS", "SERVICE_TOKEN", "APP_SECRET", "ACCESS_TOKEN"]

MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
DOB_TEMPLATES = ["born {d}", "born on {d}", "DOB: {d}", "D.O.B. {d}", "date of birth {d}", "birthday is {nd}", "b. {y}",
                 "birthdate {d}", "she was born in {my}", "he was born {d} in a small town", "dob {d}", "Date of Birth: {d}",
                 "his birthday's {nd}", "born {y}"]
NOT_DOB = ["delivered on {d}", "due {d}", "invoice dated {d}", "since {y}", "meeting on {d}", "the policy started {d}",
           "last updated {d}", "renewal in {my}", "this feature was born out of a support request", "the idea was born at a hackathon",
           "newborn photos attached", "field d.o.b is required", "d.o.b. column is empty for some rows", "Date of birth (optional)"]

NONLATIN_FIRST = {
    "ru": ["Алексей", "Дмитрий", "Сергей", "Михаил", "Наталья", "Елена", "Татьяна", "Мария", "Екатерина", "Павел", "Юлия", "Андрей"],
    "el": ["Γιώργος", "Μαρία", "Δημήτρης", "Ελένη", "Κώστας", "Σοφία"],
    "he": ["יוסי", "מיכל", "אבי", "נועה", "רונית", "איתן"],
    "ar": ["أحمد", "فاطمة", "يوسف", "مريم", "عمر", "ليلى", "خالد", "نور"],
    "th": ["สมศักดิ์", "มาลี", "ประเสริฐ", "สุภาพร"],
    "hi": ["अमित", "प्रिया", "सुनील", "अनीता", "विकास", "पूजा"],
}
NONLATIN_LAST = {
    "ru": ["Иванов", "Соколова", "Попова", "Волков", "Морозова", "Новиков", "Фёдоров", "Лебедева", "Козлов", "Егорова"],
    "el": ["Παπαδάκης", "Γεωργίου", "Οικονόμου", "Νικολάου"],
    "he": ["לוי", "מזרחי", "פרץ", "ביטון", "אברהם"],
    "ar": ["الحسن", "السيد", "حداد", "منصور", "الخطيب"],
    "th": ["แสงทอง", "ศรีสุข", "วงศ์ใหญ่"],
    "hi": ["वर्मा", "गुप्ता", "सिंह", "पटेल", "कुमार"],
}
CJK = {  # family, given, joined without a space
    "ja": (["佐藤", "鈴木", "高橋", "田中", "伊藤", "渡辺", "中村", "小林", "加藤"], ["健太", "美咲", "翔", "結衣", "大輔", "陽菜", "直樹", "由美"]),
    "zh": (["李", "张", "刘", "陈", "杨", "黄", "赵", "周", "吴", "林"], ["娜", "静", "敏", "强", "磊", "洋", "艳", "杰", "涛", "志明", "怡君"]),
    "ko": (["이", "박", "최", "정", "강", "조", "윤", "장"], ["서연", "지훈", "유진", "민호", "하은", "현우", "지아", "서준"]),
}
NONLATIN_CARRIERS = ["Refund approved for {N}.", "{N} called twice about the delivery", "Ticket opened by {N}", "assign this to {N} please",
                     "Customer name: {N}", "Recipient {N}, order {n}", "{N} wrote: the parcel is damaged", "Visit booked for {N} on Monday",
                     "contract signed by {N}", "emailed {N} the tracking link"]
NONLATIN_NOT_NAMES = ["the box was labelled 取扱注意", "menu item 拉面 sold out", "the sign says Выход", "she wrote спасибо on the card",
                      "the word for thanks is شكرا", "greeting card said 안녕하세요", "Ελληνικά subtitles are missing", "price 500 บาท",
                      "the banner read नमस्ते", "the package said 東京", "invoice in 人民币", "stamp reads ДОСТАВЛЕНО", "label: ﻿תודה רבה",
                      "file named 報告書.pdf", "tab titled 설정"]

IDENT_FORMS = ["C:\\Users\\{f}{l}\\Documents\\taxes", "pushed feature/{f}_{l}/onboarding", "attached {l}-{f}-cv.docx",
               "scp build.zip {f}@staging:/tmp", "~{f}{l}/notes.txt", "owner={f}.{l}", "git log --author={f}",
               "/var/mail/{fi}{l}", "s3://media/users/{f}-{l}/avatar.png", "{f}{l}_resume_final.pdf", "branch hotfix/{fi}{l}-typo",
               "ssh {fi}{l}@bastion", "saved to /home/{f}/Downloads", "{l}_{f}_payslip_march.pdf", "mailbox {f}.{l}@ shared queue"]
NOT_IDENT = ["tar -xf new.tar", "git clone repo/app.git", "copy original.tar to backup/", "open input.mtree", "set escape_char to ~",
             "fetch from isc.org mirrors", "cat config.yaml", "rm -rf build/", "edit main.swift", "push to origin/main",
             "saved to /usr/local/bin", "s3://assets/static/logo.png", "log written to /var/log/app.log"]

HANDLE_CUES = ["my IG is {h}", "add me on steam: {h}", "telegram @{h}", "tag {h} in the post", "{h} on the forum said it was fixed",
               "twitch: {h}", "discord {h}#{d4}", "follow @{h} for updates", "gamertag {h}", "her username was {h}", "posted by {h}",
               "DM {h} if you have questions", "my handle is @{h}"]
LOWER_CUES = ["cc {f}", "{f} pls check this", "thx {f}!", "from {f}: box arrived wet", "talked w/ {f} earlier", "{f} is out today",
              "ask {f} about the keys", "{f} and i will sort it", "per {f}, no refund", "ping {f} when ready", "sent to {f} already"]


class Doc2:
    def __init__(self):
        self.parts, self.spans, self.length = [], [], 0

    def add(self, text, label=None):
        if label and text:
            self.spans.append([self.length, self.length + len(text), label])
        self.parts.append(text)
        self.length += len(text)
        return self

    def text(self):
        return "".join(self.parts)


def fill(doc, template, values):
    """Writes `template`, labelling each {key} whose value is (text, label)."""
    i = 0
    while i < len(template):
        j = template.find("{", i)
        if j < 0:
            doc.add(template[i:]); break
        doc.add(template[i:j])
        k = template.index("}", j)
        value = values[template[j + 1:k]]
        if isinstance(value, tuple):
            doc.add(value[0], value[1])
        else:
            doc.add(str(value))
        i = k + 1


class Multi(g.Gen):
    def __init__(self, seed, held_out, prose):
        super().__init__(seed, held_out, prose)
        self.made_handles = set()

    def handle(self):
        h = super().handle()
        self.made_handles.add(h)
        return h

    # Values
    def digits(self, n):
        return "".join(self.r.choice(string.digits) for _ in range(n))

    def upper(self, n):
        return "".join(self.r.choice("ABCDEFGHJKLMNPRSTUVWXYZ") for _ in range(n))

    def alnum(self, n):
        return "".join(self.r.choice("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(n))

    def hexs(self, n):
        return "".join(self.r.choice("0123456789abcdef") for _ in range(n))

    def id_value(self):
        f = self.r.randint(0, 9)
        return [lambda: self.upper(1) + self.digits(8), lambda: f"{self.digits(3)}-{self.digits(2)}-{self.digits(4)}",
                lambda: f"{self.digits(3)} {self.digits(3)} {self.digits(3)}", lambda: self.digits(8) + self.upper(1),
                lambda: f"{self.upper(2)}{self.digits(6)}{self.upper(1)}", lambda: f"{self.digits(2)}.{self.digits(3)}.{self.digits(3)}-{self.r.choice('0123456789K')}",
                lambda: self.digits(self.r.randint(7, 12)), lambda: f"{self.upper(3)}-{self.digits(5)}",
                lambda: f"{self.digits(4)} {self.digits(4)} {self.digits(4)}", lambda: f"{self.upper(1)}{self.digits(3)}-{self.digits(3)}-{self.digits(2)}-{self.digits(3)}-{self.digits(1)}"][f]()

    def password(self):
        f = self.r.randint(0, 4)
        w = lambda: self.c(PW_WORDS)
        return [lambda: f"{w()}-{w().capitalize()}-{self.r.randint(10, 99)}", lambda: f"{w().capitalize()}!{w()}{self.r.randint(1, 9)}",
                lambda: self.alnum(self.r.randint(10, 16)) + self.c(["!", "#", "$", "%", ""]), lambda: f"{w()}{self.r.randint(1000, 9999)}",
                lambda: f"{w().capitalize()}{w().capitalize()}{self.c(['!', '?', '@'])}{self.r.randint(1, 99)}"][f]()

    def date(self, with_year=True):
        d, m, y = self.r.randint(1, 28), self.r.randint(1, 12), self.r.randint(1938, 2008)
        if not with_year:
            return self.c([f"{MONTHS[m - 1]} {d}", f"{d} {MONTHS[m - 1]}", f"the {d}th of {MONTHS[m - 1]}"])
        return self.c([f"{MONTHS[m - 1]} {d}, {y}", f"{d} {MONTHS[m - 1]} {y}", f"{d} {MONTHS[m - 1][:3]} {y}", f"{m}/{d}/{str(y)[2:]}",
                       f"{m:02d}/{d:02d}/{y}", f"{y}-{m:02d}-{d:02d}", f"{d:02d}.{m:02d}.{y}", f"{d}/{m}/{y}"])

    def org_name(self):
        head = self.c(ORG_HEADS) if self.p(0.6) else self.surname()
        if self.p(0.15):
            return f"{self.surname()} & {self.surname()} {self.c(['LLP', 'Solicitors', 'Accountants'])}"
        return f"{head} {self.c(ORG_TAILS)}"

    def who(self):
        """A person in subject position, labelled."""
        roll = self.r.random()
        if roll < 0.5:
            name = self.given() + (" " + self.surname() if self.p(0.5) else "")
            return (name, "PERSON")
        return (self.c(["She", "He", "My sister", "Her husband", "The caller", "The tenant", "My son", "Our client", "I"]), None)

    def nonlatin_name(self):
        if self.p(0.35):
            family, given = CJK[self.c(list(CJK))]
            return self.c(family) + self.c(given)
        script = self.c(list(NONLATIN_FIRST))
        first = self.c(NONLATIN_FIRST[script])
        return first if self.p(0.2) else first + " " + self.c(NONLATIN_LAST[script])

    # Segments: each writes one line or sentence.
    def place(self, doc):
        w = self.who()
        fill(doc, "{w} " + self.c(PLACE_CUES) + self.c([".", "", " last year.", ", apparently."]), {"w": w, "p": (self.c(TOWNS), "LOCATION")})

    def employer(self, doc):
        if self.p(0.4):
            fill(doc, self.c(VENDOR_CUES), {"o": self.org_name()})
            return
        fill(doc, self.c(EMPLOYER_CUES) + self.c([".", "", " and hates it.", "."]),
             {"w": self.who(), "o": (self.org_name(), "ORG"), "job": self.c(JOBS), "n": self.r.randint(2, 19),
              "y": self.r.randint(2001, 2024), "m": self.c(MONTHS)})

    def ids(self, doc):
        roll = self.r.random()
        if roll < 0.35:
            n = self.r.randint(100, 99999)
            fill(doc, self.c(NOT_ID), {"n": n, "y": self.r.randint(2019, 2026), "s": self.digits(4), "a": self.r.randint(0, 9),
                                       "b": self.r.randint(0, 20), "c": self.r.randint(0, 30), "p": self.c([22, 443, 5432, 8080, 6379]),
                                       "h": self.hexs(12), "r": self.r.randint(1, 400), "sku": self.upper(3) + "-" + self.digits(5),
                                       "track": self.upper(2) + self.digits(9) + self.upper(2)})
        elif roll < 0.42:
            fill(doc, self.c(NOT_REF), {"r": self.r.randint(1, 40), "s": self.r.randint(1, 4), "y": self.r.randint(1990, 2025),
                                        "n": self.r.randint(100, 9999), "k": self.r.randint(1, 999)})
        elif roll < 0.75:
            label = self.c(ID_LABELS)
            fill(doc, self.c(ID_TEMPLATES), {"l": label, "L": label[0].upper() + label[1:], "v": (self.id_value(), "ID")})
        elif roll < 0.85:
            ref = self.c(REF_LABELS)
            value = self.c([lambda: f"{self.digits(self.r.randint(4, 5))}/{self.digits(2)}", lambda: f"{self.digits(self.r.randint(3, 6))}/{self.r.randint(1990, 2025)}",
                            lambda: f"{self.upper(2)}-{self.digits(4)}/{self.digits(2)}", self.id_value])()
            fill(doc, self.c(REF_TEMPLATES), {"r": ref, "R": ref[0].upper() + ref[1:], "v": (value, "ID"), "w": self.who()})
        else:
            fill(doc, self.c(ID_BARE), {"v": (self.id_value(), "ID")})

    def secret(self, doc):
        if self.p(0.35):
            fill(doc, self.c(NOT_SECRET), {"hex40": self.hexs(40), "hex64": self.hexs(64), "hex16": self.hexs(16),
                                           "uuid": f"{self.hexs(8)}-{self.hexs(4)}-{self.hexs(4)}-{self.hexs(4)}-{self.hexs(12)}"})
            return
        tok = self.c(["", "qv_", "tok_", "key-", "pat_", "live_"]) + self.alnum(self.r.randint(24, 44))
        fill(doc, self.c(SECRET_TEMPLATES), {"t": self.c(["wifi", "router", "admin panel", "VPN", "email", "laptop", "alarm", "portal"]),
                                             "v": (self.password(), "SECRET"), "pin": (self.digits(self.c([4, 4, 6])), "SECRET"),
                                             "tok": (tok, "SECRET"), "b64": (self.alnum(28) + "==", "SECRET"), "hex": (self.hexs(self.c([32, 40, 64])), "SECRET"),
                                             "u": self.c(["deploy", "admin", "ci", "backup", self.given().lower()]),
                                             "host": self.c(["git.example.test", "db.internal:5432", "files.local"]), "ENV": self.c(ENVS),
                                             "rc": (f"{self.alnum(5)}-{self.alnum(5)}", "SECRET")})

    def dob(self, doc):
        if self.p(0.4):
            fill(doc, self.c(NOT_DOB), {"d": self.date(), "y": self.r.randint(1990, 2025),
                                         "my": f"{self.c(MONTHS)} {self.r.randint(2018, 2027)}"})
            return
        y = self.r.randint(1938, 2008)
        fill(doc, self.c(["{w} was ", "Applicant ", "Patient: {name}, ", "{w} - ", "verified caller, ", ""]) + self.c(DOB_TEMPLATES),
             {"w": self.who(), "name": (self.given() + " " + self.surname(), "PERSON"), "d": (self.date(), "DOB"),
              "nd": (self.date(False), "DOB"), "y": (str(y), "DOB"), "my": (f"{self.c(MONTHS)} {y}", "DOB")})

    def nonlatin(self, doc):
        if self.p(0.3):
            doc.add(self.c(NONLATIN_NOT_NAMES))
            return
        fill(doc, self.c(NONLATIN_CARRIERS), {"N": (self.nonlatin_name(), "PERSON"), "n": self.r.randint(1000, 99999)})

    def identifier_names(self, doc):
        if self.p(0.4):
            doc.add(self.c(NOT_IDENT))
            return
        f, l = self.given().lower(), self.surname().lower()
        form = self.c(IDENT_FORMS)
        # Separate parts are names; parts glued together are a handle.
        values = {"f": (f, "PERSON"), "l": (l, "PERSON"), "fi": f[0]}
        if "{f}{l}" in form or "{fi}{l}" in form or "{f}.{l}" in form:
            joined = form.replace("{f}{l}", f + l).replace("{fi}{l}", f[0] + l).replace("{f}.{l}", f + "." + l)
            glued = f + l if "{f}{l}" in form else f[0] + l if "{fi}{l}" in form else f + "." + l
            start = joined.index(glued)
            doc.add(joined[:start]); doc.add(glued, "USERNAME"); doc.add(joined[start + len(glued):])
            return
        if "{f}@" in form or "/home/{f}/" in form:
            values["f"] = (f, "USERNAME")
        fill(doc, form, values)

    def handles(self, doc):
        h = self.handle() if self.p(0.6) else self.c(["xX{w}Xx", "{w}{n}", "{f}_{w}", "the_{w}", "{w}.{f}"]).format(
            w=self.c(PW_WORDS), n=self.r.randint(1, 999), f=self.given().lower())
        fill(doc, self.c(HANDLE_CUES), {"h": (h, "USERNAME"), "d4": self.digits(4)})

    def lower_first(self, doc):
        fill(doc, self.c(LOWER_CUES), {"f": (self.plain_given().lower(), "PERSON")})

    def prose_line(self, doc):
        if self.prose:
            doc.add(self.c(self.prose))

    NEW = ["place", "employer", "ids", "secret", "dob", "nonlatin", "identifier_names", "handles", "lower_first", "prose_line"]

    def document2(self):
        if self.p(0.4):
            old = self.document()
            doc = Doc2()
            text = old.text()
            for s, e in old.spans:
                piece = text[s:e]
                handle = piece in self.made_handles or any(ch.isdigit() for ch in piece) or any(ch in "._@" for ch in piece)
                doc.spans.append([s, e, "USERNAME" if handle else "PERSON"])
            doc.parts, doc.length = [text], len(text)
            self.made_handles.clear()
            return doc
        doc = Doc2()
        for i in range(self.r.randint(1, 3)):
            if i:
                doc.add(self.c([" ", "\n", "\n\n", ". "]))
            getattr(self, self.c(self.NEW))(doc)
        self.made_handles.clear()
        return doc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=80000)
    parser.add_argument("--seed", type=int, default=11)
    parser.add_argument("--prose")
    args = parser.parse_args()
    prose = open(args.prose).read().splitlines() if args.prose else []
    gen = Multi(args.seed, g.held_out_vocabulary(), prose)
    for _ in range(args.count):
        doc = gen.document2()
        print(json.dumps({"text": doc.text(), "spans": doc.spans}, ensure_ascii=False))


if __name__ == "__main__":
    main()
