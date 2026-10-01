"""Writes labelled training text for the name model as JSON lines.

Each line is {"text": ..., "spans": [[start, end], ...]} with code point
offsets of every word that names a person. Nothing here reuses the NameGaps
benchmark: its names, word-names and tools are read from GapCases.swift and
left out, so the benchmark measures what the model learned, not what it saw.

    python generate.py --count 200000 --seed 7 --prose prose.txt > train.jsonl
"""
import argparse
import json
import random
import re
from pathlib import Path

FIRST = """
Abebe Adaeze Adebayo Adriana Agnieszka Ahmad Aiko Ainhoa Akash Akosua Alejandro Aleksander Alessandro Alexei Alibek Alina Alisha Amadou Amara Ambrose
Amelie Anahita Anastasia Andrzej Aneta Angelica Anil Anjali Annika Antoine Antonella Anupama Aoife Araceli Arash Arnav Arturo Asel Astrid Ayaan Ayodele
Babajide Bahar Baraka Bartosz Bastian Benedikt Bettina Bilal Birgit Bongani Branislav Brigid Bruno Busisiwe Caetano Caio Carmen Catalina Cathal Cecilia
Chen Chidi Chinedu Chloe Christoph Cian Ciara Claudia Clementine Cosmin Cristina Dagny Dalia Damla Daniela Darius Dariusz Dayo Deepika Deniz Desmond
Dilnoza Dimitra Dinh Dorota Ebru Edwige Efua Eilidh Eitan Ekaterina Elif Elodie Emine Emre Enrique Erzsebet Esperanza Esra Esther Eun-ji Ezinne Fabian
Fadumo Farah Farid Federica Felipe Fernanda Filip Finnegan Folake Francesca Fredrik Gabriela Gaurav Geraldine Gintaras Giorgos Giovanni Githinji Gonzalo
Guadalupe Gunnar Gustavo Habib Hadiza Hakan Halima Hannelore Haruto Hassan Heikki Helga Henrik Hiroshi Hoang Hugo Ibrahim Ifeoma Ignacio Ilse Imani Imran
Ines Ioana Irina Isabela Ishaan Itzel Ivana Jakub Jamal Jana Janek Javier Jelena Jiho Jin-woo Joanna Joao Johanna Jonas Jorge Josefina Jovana Juliana
Jun Jurgen Kamala Kamil Karim Karolina Kasia Katarzyna Kavya Kazuki Keisha Kemal Kerstin Khadija Kieran Kimiko Kirra Klaus Kwame Lars Latisha Leandro
Lennart Leticia Liam Liang Lior Liesbeth Lorenzo Luana Ludmila Luis Lwazi Magdalena Mahmoud Malak Malgorzata Manon Manuel Marcin Mariam Marisol Marta
Martina Masato Matteo Maximilian Mehmet Mehwish Milan Milos Minh Miriam Mohammed Moana Monika Mustafa Nadine Naledi Nasrin Natalia Naveen Neha Nikhil
Nikolai Nikos Niamh Nils Noor Nora Nuno Obinna Odette Olga Olumide Oskar Pablo Paola Paulina Pavel Pilar Pooja Praveen Precious Radek Radhika Rafaela
Rahul Raquel Ravi Reza Rodrigo Roisin Rosalind Rui Ruslan Ryo Sabine Sadia Sakura Salma Samir Sandeep Sanjay Santiago Sara Sebastien Seo-yeon Sergei
Shabnam Shreya Sibusiso Signe Silvia Simone Sinead Sipho Soledad Sophie Stanislav Stefan Sunita Suresh Svetlana Tadeusz Takumi Tamar Tatiana Tendai
Teodora Thiago Tiago Timur Tobias Tuan Tunde Ulrike Umar Usha Valentina Vasilis Veronika Vikram Vilja Vincenzo Viviane Wanjiru Wei Wojciech Xavier
Ximena Yaw Yaroslav Yasmin Yerlan Yetunde Yosef Youssef Yusuf Zainab Zanele Zeynep Zhanna Zoltan Zuzana Oisin Mairead Paddy Gwen Rhiannon Bronwen Dylan
Hamish Isla Callum Fiona Duncan Morag Eamon Grainne Tadhg Una Leopold Ottilie Wilhelmina Bertrand Gaspard Solene Margaux Anouk Bram Maarten Femke Sander
Joris Lotte Hedda Ingeborg Sigrid Torbjorn Eero Aino Kalle Jaakko Brynja Einar Halldor Gudrun Thorsten Wiebke Gerrit Annegret Mats Kristian Liv
Cormac Declan Kenna Lachlan Mackenzie Brody Tamsin Jarrah Talia Anika Reuben Saul Mordechai Yitzhak Avital Noa Shira Batsheva Rivka Yael Ori Dov
Emmanuel Kofi Abena Kwabena Ama Nana Esi Kojo Afia Yaa Akua Chukwuemeka Ngozi Nnamdi Uchenna Amaka Kelechi Ikenna Oluchi Somto Tobenna Zola Thandeka
Lindiwe Nomvula Mandla Themba Lerato Kagiso Tshepo Palesa Neo Refilwe Bheki Dumisani Nokuthula Sizwe Xolani Fikile Andile Siyabonga Thulani Mpho
""".split()

LAST = """
Abdullahi Acheampong Adebayo Agarwal Aguilar Ahmadi Akhtar Alvarado Amadi Andersson Antonelli Appiah Arslan Asante Babatunde Bajwa Balogun Banerjee
Barros Bauer Becker Bianchi Bjorklund Blanco Bondarenko Bose Brandt Bustamante Cabrera Calderon Campos Cardoso Carvalho Castillo Cerny Chakraborty
Chaudhry Chen Cho Choi Chowdhury Ciobanu Conti Contreras Costa Cunha Czerwinski Dahl Dang Das Delgado Demir Desai Dimitrov Dinh Dogan Domingo Dubois
Duarte Dvorak Eklund Engel Eriksson Estrada Fabbri Farouk Fernandes Fischer Fontaine Fournier Fuentes Fujita Gallagher Garrido Ghosh Giordano Girard
Golubev Gomes Guerrero Gupta Guzman Haas Hansen Hartmann Hashemi Hayashi Hoang Horvat Hosseini Huang Hussain Ibrahim Ikeda Ivanova Jankowski Jensen
Jovanovic Kaczmarek Kamara Kapoor Karimi Kaya Keller Khalil Khan Kiplagat Kobayashi Koch Kovac Kovalenko Kowalski Kozlov Krishnan Kruger Kumar Laine
Lam Larsen Laurent Lefebvre Leitner Lehmann Levy Lim Lindberg Lombardi Lozano Lund Mahlangu Majewski Malik Mancini Marchetti Markovic Marques Matsumoto
Medina Mehta Meier Mendoza Mensah Mishra Molina Mondal Moretti Mukherjee Muller Murray Mwangi Nakagawa Navarro Ndlovu Neumann Nielsen Nikolaidis
Novak Nowak Nunez Obi Ochieng Odhiambo Ogunleye Ohara Okeke Okonjo Olsen Omondi Onyango Orlov Ozturk Pacheco Palmer Papadopoulos Pavlov Pereira Perera
Petersen Pham Pillai Pinto Popov Quintero Rahimi Rao Reddy Ricci Rinaldi Rios Rocha Romano Rossi Roy Rubio Saeed Saito Salazar Santos Sato Schmidt
Schneider Schulz Serrano Shah Sharma Shevchenko Silva Singh Soares Sokolov Suarez Sutherland Suzuki Svensson Szymanski Takahashi Tran Trivedi Ueda
Uzor Valdez Vargas Vasquez Verma Vogel Volkov Wagner Walczak Wang Watanabe Weber Wieczorek Wolff Wu Xu Yamada Yamamoto Yang Yildiz Yoshida Zapata
Zielinski Zimmermann Zubiri Abernathy Blackwood Callaghan Donnelly Ellsworth Fairbanks Gallardo Halvorsen Iwasaki Jablonski Kavanagh Lachance
Mbatha Nkosi Dlamini Zulu Khumalo Mokoena Molefe Sithole Ngcobo Mthembu Okoro Eze Nwosu Chukwu Adeleke Oyelaran Bankole Owusu Boateng Ansah Darko
Quartey Tetteh Asamoah Kariuki Njoroge Wanjiku Kimani Mutua Achieng Otieno Abdi Warsame Haile Tesfaye Bekele Girma Alemu Tadesse Gebremedhin
""".split()

PARTICLES = ["van", "van der", "de", "de la", "del", "da", "dos", "von", "bin", "al", "el", "ter", "di", "le"]
FAMILY_FIRST = [("Wang", "Lei"), ("Li", "Na"), ("Zhang", "Wei"), ("Liu", "Yang"), ("Chen", "Jing"), ("Kim", "Min-jun"), ("Lee", "Seo-yeon"), ("Pham", "Thi Hoa"),
                ("Tran", "Van Duc"), ("Sato", "Haruka"), ("Suzuki", "Ren"), ("Takahashi", "Mio"), ("Huang", "Mei-ling"), ("Lim", "Jia Hui"), ("Ng", "Wai Kit"), ("Choi", "Ji-hoon")]

# Words that are also given names. Each has sentences using it as a plain word.
WORD_NAMES = {
    "Pat": ["pat the surface dry before applying", "a quick pat on the back"],
    "Rich": ["the rich text editor strips formatting", "a rich set of filters"],
    "Penny": ["not a penny was refunded", "we saved every penny on shipping"],
    "Amber": ["the amber warning light stays on", "status is amber for this sprint"],
    "Crystal": ["the crystal oscillator drifts", "crystal clear audio on the call"],
    "Iris": ["the iris scanner rejected the badge"],
    "Ivy": ["ivy covers the north wall of the depot"],
    "Holly": ["holly wreaths ship in november"],
    "Joy": ["no joy on the second retry", "it was a joy to work with"],
    "Max": ["set max retries to five", "the max upload size is ten megabytes"],
    "Victor": ["the victor of the bid gets the contract"],
    "Dean": ["the dean of admissions signed it"],
    "Frank": ["a frank discussion about the budget", "to be frank the numbers are off"],
    "Sandy": ["the sandy soil near the site drains fast"],
    "Robin": ["round robin load balancing", "a robin nested above the door"],
    "Drew": ["she drew a diagram of the flow", "the match drew a big crowd"],
    "Rusty": ["my sql is a bit rusty", "the rusty hinge squeaks"],
    "Brook": ["the brook floods the lower lot", "we will not brook any delay"],
    "Heather": ["heather grey hoodies are back in stock"],
    "Olive": ["olive oil prices went up"],
    "Dale": ["the cottage sits in the dale"],
    "Glen": ["the trail runs through the glen"],
    "Lane": ["merge into the left lane", "the fast lane for priority tickets"],
    "Cliff": ["a cliff in the revenue chart"],
    "Wade": ["we had to wade through the logs"],
    "Miles": ["the depot is twelve miles away", "frequent flyer miles expired"],
    "Reed": ["a reed switch in the sensor"],
    "Grant": ["grant read access to the folder", "the research grant was renewed"],
    "Sterling": ["prices are quoted in sterling", "sterling silver cufflinks"],
    "Hazel": ["hazel nuts are on backorder"],
    "Autumn": ["the autumn release slipped a week"],
    "Melody": ["the hold melody loops every minute"],
    "Jade": ["the jade pendant was returned"],
    "Pearl": ["the pearl necklace arrived broken"],
    "Ginger": ["ginger tea is in the kitchen"],
    "Cole": ["cole slaw with the lunch order"],
    "Rocky": ["a rocky start to the quarter", "the rocky road flavour sold out"],
    "Carol": ["the carol service is at six"],
    "Ray": ["a ray of light through the window", "ray tracing is enabled"],
    "Gene": ["the gene panel results are pending"],
    "Lily": ["lily bulbs ship in spring"],
    "Daisy": ["daisy chain the monitors"],
    "Willow": ["a willow tree by the gate"],
    "Sage": ["sage green is the new accent colour"],
    "Angel": ["an angel investor joined the round"],
    "Norm": ["that is the norm for this region", "the l2 norm of the vector"],
    "Guy": ["a guy from the vendor called", "the delivery guy left it outside"],
    "Don": ["don the gloves before handling"],
    "Art": ["the cover art is final"],
    "Sue": ["they threatened to sue over the delay"],
    "May": ["you may need to restart", "the deadline may move"],
    "August": ["an august institution"],
    "Kit": ["the starter kit ships tomorrow"],
    "Basil": ["basil pesto is out of stock"],
    "Barry": [],
}

# Things named like people that are not people.
TOOLS = ["Ansible", "Kafka", "Kibana", "Docker", "Terraform", "Bamboo", "Travis", "Hugo", "Gatsby", "Sentry", "Jira", "Confluence", "Heroku", "Python",
         "Perl", "Haskell", "Pascal", "Erlang", "Elixir", "Lua", "Dart", "Swift", "Kotlin", "Scala", "Groovy", "Bazel", "Gradle", "Jupyter", "Pandas",
         "Django", "Flask", "Rails", "Laravel", "Hadoop", "Spark", "Airflow", "Celery", "Redis", "Postgres", "Oracle", "Cortana", "Bixby", "Watson",
         "Jarvis", "Copilot", "Lambda", "Fargate", "Tesla", "Edison", "Ubuntu", "Debian", "Fedora", "Jenkinsfile", "Ollie", "Clippy", "Hubot", "Renovate",
         "Prometheus", "Loki", "Thanos", "Jaeger", "Zipkin", "Vault", "Consul", "Nomad", "Kubernetes", "Helm", "Argo", "Flux", "Tekton", "Harbor",
         "Nginx", "Apache", "Tomcat", "Jetty", "Mongo", "Neo4j", "Clickhouse", "Presto", "Trino", "Hive", "Pig", "Sqoop", "Oozie", "Zookeeper", "Marathon"]
# Companies are invented here, never real ones, in the forms that make a
# company look like a person: surnames joined, or a surname with a firm word.
ORG_FORMS = ["{a} & {b}", "{a} {b} & Co", "{a} Foundation", "{a} Capital", "{a} Partners", "{a}'s", "{a} Motor", "{a} Bank", "{a} & Sons",
             "{a} {b} Securities", "{a} Hall", "{a} Center", "{f} {a} Living", "{a} Brothers", "{a} Trust", "{a} Institute", "{a} Bay Logistics"]
PLACES = ["Denver", "Lisbon", "Nairobi", "Osaka", "Bogota", "Krakow", "Lagos", "Hanoi", "Leeds", "Perth", "Quebec", "Tbilisi", "Accra", "Manila", "Lyon",
          "Porto", "Sevilla", "Gdansk", "Durban", "Cork", "Bergen", "Tampere", "Utrecht", "Ghent", "Graz", "Brno", "Cluj", "Izmir", "Pune", "Cebu",
          "Charlotte", "Madison", "Eugene", "Lafayette", "Lorraine", "Adelaide", "Alexandria", "Augusta", "Beatrice", "Chester", "Elizabeth", "Marion",
          "Victoria Station", "St. Louis", "San Jose", "Santa Clara", "Mount Vernon", "Port Louis"]
MONTHS = ["January", "February", "March", "July", "September", "October", "November", "December"]
DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
TITLES = ["Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "Mr", "Ms", "Dr", "Mx.", "Sr.", "Sra.", "Herr", "Frau", "Mme", "M."]
NOT_PEOPLE_HANDLES = ["ops-bot", "build.agent", "release_2026", "admin", "root", "svc.payments", "deploy-bot", "ci", "noreply", "support", "billing",
                      "jenkins-agent", "github-actions", "renovate[bot]", "sre-oncall", "data.pipeline", "backup_job", "cron", "www-data", "postgres", "system"]
STARTERS = ["Later", "Then", "Meanwhile", "Also", "However", "Afterwards", "Next", "Finally", "Today", "Tomorrow", "Yesterday", "Again", "Still",
            "Otherwise", "Instead", "Overall", "Unfortunately", "Luckily", "Apparently", "Separately", "Additionally", "Please", "Note", "Update", "Edit"]
CODES = ["WA", "CA", "NY", "TX", "FL", "IL", "OR", "CO", "MA", "GA", "NC", "AZ", "ON", "QC", "BC", "NSW", "VIC", "US", "UK", "DE", "FR", "ES", "BR", "IN", "JP",
         "SLA", "ETA", "CEO", "CTO", "API", "SSO", "VPN", "PTO", "EOD", "ASAP", "FYI", "QA", "HR", "IT", "PR", "OK", "N/A", "TBD", "USD", "EUR", "GBP"]
FIELD_WORDS = ["line", "address", "street", "field", "item", "page", "test", "user", "node", "row", "col", "step", "part", "phase", "server", "host",
               "room", "gate", "lane", "zone", "slot", "level", "tier", "batch", "group", "option", "choice", "answer", "image", "file", "var", "temp",
               "phone", "email", "contact", "name", "city", "region", "ref", "code", "key", "id", "attr", "param", "arg", "col", "sheet", "tab", "run"]
ENUM_KEYS = ["relationship", "gender", "department", "status", "role", "type", "tier", "plan", "theme", "locale", "currency", "method", "frequency",
             "priority", "level", "category", "state", "source", "channel", "team", "title", "kind", "mode", "test", "enabled", "verified", "object"]
ENUM_VALUES = ["female", "male", "nonbinary", "parent", "spouse", "child", "sibling", "friend", "guardian", "active", "inactive", "pending", "approved",
               "admin", "member", "guest", "true", "false", "null", "none", "None", "nil", "undefined", "yes", "no", "high", "low", "medium", "daily",
               "weekly", "monthly", "card", "cash", "usd", "eur", "en", "en-US", "dark", "light", "Human Resources", "Engineering", "Sales", "Marketing",
               "Finance", "Customer Success", "Legal", "Operations", "Research", "Product", "Design", "Mother", "Father", "Partner", "Manager",
               "Senior Engineer", "Head of Sales", "web", "mobile", "email", "sms", "void", "payment", "refund", "processing", "requires_action",
               "visa", "mastercard", "amex", "discover", "debit", "credit", "paypal", "wire", "ach", "sepa", "checking", "savings"]
# Machine statuses and verdicts: snake_case or upper case, never a handle.
STATUS_VALUES = [v for w in ["not_found", "no_match", "partial_match", "exact_match", "in_progress", "timed_out", "pending_review", "not_applicable",
                             "unavailable", "unverified", "verified", "mismatch", "match", "exact", "partial", "not_checked", "manual_review", "auto_approved",
                             "rate_limited", "out_of_stock", "on_hold", "past_due", "soft_fail", "hard_fail", "no_data", "not_provided", "opted_out"]
                 for v in (w, w, w.upper())]
DEPARTMENTS = ["Customer Success", "Platform", "Engineering", "Sales", "Marketing", "Finance", "Payroll", "Support", "Data", "Security", "Legal",
               "Operations", "Product", "Design", "Research", "Billing", "Procurement", "Partnerships", "Growth", "Infrastructure", "Quality"]
ROLES = ["Lead", "Manager", "Director", "Specialist", "Associate", "Analyst", "Coordinator", "Engineer", "Architect", "Advisor", "Officer",
         "Intern", "Head", "Representative", "Consultant", "Administrator", "Strategist"]
# Occupations as job titles, with the qualifiers they often carry.
OCCUPATIONS = [q + o for o in ["Nurse", "Pharmacist", "Technician", "Teacher", "Accountant", "Paralegal", "Therapist", "Electrician", "Clerk", "Cashier", "Chef",
                               "Barista", "Mechanic", "Surgeon", "Physician", "Dentist", "Hygienist", "Supervisor", "Receptionist", "Plumber", "Carpenter",
                               "Librarian", "Pilot", "Attorney", "Auditor", "Underwriter", "Teller", "Recruiter", "Designer", "Developer", "Scientist",
                               "Researcher", "Professor", "Lecturer", "Tutor", "Counselor", "Paramedic", "Firefighter", "Midwife", "Radiographer",
                               "Bookkeeper", "Machinist", "Welder", "Courier", "Dispatcher", "Caregiver", "Optometrist", "Veterinarian", "Surveyor"]
               for q in ["", "", "Registered ", "Licensed ", "Certified ", "Practical ", "Clinical ", "Senior ", "Charge ", "Dental ", "Staff "]]
LABEL_NOUNS = ["address", "name", "number", "code", "date", "email", "phone", "company", "title", "holder", "city", "country", "region", "notes",
               "contact", "reference", "method", "preference", "line", "details"]
LABEL_HEADS = ["Street", "Email", "Last", "First", "Middle", "Preferred", "Display", "Billing", "Shipping", "Postal", "Company", "Account", "Contact",
               "Mailing", "Home", "Work", "Mobile", "Primary", "Secondary", "Legal", "Full", "Given", "Family", "Birth", "Delivery", "Payment"]
TITLE_KEYS = ["job_title", "jobTitle", "JobTitle", "job-title", "position", "role", "title", "designation", "occupation"]
PERSON_KEYS = ["name", "owner", "assignee", "author", "contact", "manager", "reviewer", "customer", "patient", "employee", "first_name", "last_name",
               "full_name", "signed_by", "created_by", "firstName", "lastName", "displayName", "approver", "requester"]
STREET_TYPES = ["St", "Rd", "Ave", "Blvd", "Ln", "Dr", "Ct", "Way", "Pl", "Terrace", "Street", "Road", "Avenue", "Lane", "Drive", "Hollow", "Row", "Close"]
PRONOUNS = ["her", "him", "them", "us", "me", "you", "it", "his", "their", "our", "my", "your", "everyone", "someone", "nobody"]
# Word-names that also work as modifiers before a noun: plants, colours, materials.
MODIFIER_NAMES = ["Amber", "Crystal", "Iris", "Ivy", "Holly", "Heather", "Olive", "Hazel", "Jade", "Pearl", "Ginger", "Lily", "Daisy", "Willow", "Sage", "Sandy", "Rusty", "Autumn", "Sterling"]
NOUNS = ["tenant", "customer", "client", "vendor", "user", "account", "team", "manager", "driver", "courier", "landlord", "patient", "member", "admin",
         "owner", "agent", "partner", "supplier", "buyer", "seller", "staff", "string", "number", "object", "value", "node", "service", "region", "cluster"]
FOREIGN = [
    "Le client {p} habite à {place} depuis {month}.", "La cliente {p} a appelé pour sa facture.", "Les documents de {p} sont arrivés.",
    "El cliente {p} pidió un reembolso.", "La paciente {p} llamó desde {place} por su cita.", "Los datos de {p} están incompletos.",
    "Der Kunde {p} hat die Rechnung bezahlt.", "Die Bestellung von {p} ist unterwegs.", "Das Konto von {p} wurde gesperrt.",
    "O cliente {p} mora em {place}.", "A encomenda de {p} chegou ontem.", "Il cliente {p} ha chiamato ieri.", "La fattura di {p} è pronta.",
    "De klant {p} heeft betaald.", "Het pakket voor {p} is onderweg.", "Een bericht van {p} over de levering.",
]
FOREIGN_PLAIN = ["Le paiement est en attente.", "La livraison est prévue lundi.", "El pedido salió ayer.", "Los precios subieron en marzo.",
                 "Der Vertrag endet im Mai.", "Die Lieferung kommt morgen.", "Das Paket ist beschädigt.", "O pagamento foi recusado.",
                 "Il pacco è in ritardo.", "De factuur is betaald.", "Het account is geblokkeerd.", "Les frais sont remboursés."]
SUFFIXES = ["LLC", "Inc", "Ltd", "GmbH", "Corp", "Group", "Labs", "Systems", "Partners", "Holdings", "Traders", "Logistics", "Foods", "Media", "Health"]
COMMON_CAPS = ["Invoice", "Refund", "Order", "Account", "Billing", "Support", "Shipping", "Customer", "Ticket", "Priority", "Status", "Update", "Team",
               "Platform", "Finance", "Legal", "Security", "Release", "Sprint", "Roadmap", "Dashboard", "Settings", "Profile", "Report", "Summary", "Note",
               "Escalation", "Warehouse", "Courier", "Delivery", "Payment", "Subscription", "Plan", "Premium", "Enterprise", "Starter", "Pro", "Beta"]
VERBS_PAST = ["approved", "flagged", "rejected", "escalated", "reopened", "closed", "updated", "reviewed", "signed", "requested", "cancelled", "confirmed",
              "disputed", "forwarded", "merged", "reverted", "deployed", "paused", "refunded", "booked", "shipped", "scheduled", "uploaded", "deleted"]
OBJECTS = ["the refund", "the invoice", "the ticket", "the order", "the contract", "the change", "the request", "the claim", "the payment", "the booking",
           "the renewal", "the transfer", "the shipment", "the form", "the pull request", "the budget", "the incident", "the quote", "the return label"]
TAILS = ["this morning", "yesterday", "on Friday", "last week", "an hour ago", "before lunch", "after the call", "without a receipt", "twice", "again",
         "by mistake", "for the second time", "late last night", "", "", ""]


class Inventor:
    """Makes up names that read like the ones it learned from, so the model
    has to judge a name by its shape and context rather than recall it."""

    def __init__(self, names, rng):
        self.r = rng
        self.next = {}
        for name in names:
            padded = "^^" + name.lower() + "$"
            for i in range(len(padded) - 2):
                self.next.setdefault(padded[i:i + 2], []).append(padded[i + 2])
        self.known = {n.lower() for n in names}

    def make(self):
        while True:
            state, out = "^^", ""
            while len(out) < 12:
                ch = self.r.choice(self.next[state])
                if ch == "$":
                    break
                out += ch
                state = state[1] + ch
            if 3 <= len(out) <= 11 and out not in self.known:
                return out.capitalize()


def dictionary_words():
    try:
        words = [w.strip() for w in open("/usr/share/dict/words")]
    except OSError:
        return ["widget", "lantern", "harbor", "copper", "orbit", "falcon", "meadow", "ember", "quartz", "summit"]
    return [w for w in words if w.isalpha() and w.islower() and 4 <= len(w) <= 9]


def held_out_vocabulary():
    """Every word the NameGaps benchmark uses as a name, word-name or tool."""
    source = Path(__file__).resolve().parents[2] / "Tests/ScrubCoreTests/NameGaps/GapCases.swift"
    text = source.read_text()
    words = set()
    for literal in re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', text):
        if "\\(" in literal:
            continue
        for word in re.findall(r"[^\W\d_][\w'’-]*", literal):
            if word[0].isupper():
                words.add(word.lower())
    return words


class Doc:
    def __init__(self):
        self.parts = []
        self.spans = []
        self.length = 0

    def add(self, text, name=False):
        if name and text:
            self.spans.append([self.length, self.length + len(text)])
        self.parts.append(text)
        self.length += len(text)
        return self

    def text(self):
        return "".join(self.parts)


class Gen:
    def __init__(self, seed, held_out, prose=()):
        self.r = random.Random(seed)
        self.prose = list(prose)
        keep = lambda words: [w for w in words if w.lower() not in held_out]
        self.first = keep(FIRST)
        self.last = keep(LAST)
        self.word_names = {k: v for k, v in WORD_NAMES.items() if k.lower() not in held_out}
        self.tools = keep(TOOLS)
        self.places = PLACES
        self.invent_first = Inventor(self.first, self.r)
        self.invent_last = Inventor(self.last, self.r)
        self.words = [w for w in dictionary_words() if w not in held_out]

    def c(self, values):
        return self.r.choice(values)

    def p(self, chance):
        return self.r.random() < chance

    def given(self):
        if self.p(0.12) and self.word_names:
            return self.c(list(self.word_names))
        return self.invent_first.make() if self.p(0.5) else self.c(self.first)

    def surname(self):
        return self.invent_last.make() if self.p(0.5) else self.c(self.last)

    def label(self):
        """A form label or question: "Street address", "How should we reach you?"."""
        if self.p(0.3):
            return f"{self.c(['How', 'When', 'Where', 'Why', 'What'])} {self.c(['should', 'can', 'did', 'would'])} {self.c(['we', 'you', 'they'])} {self.c(['reach', 'contact', 'bill', 'ship to', 'call', 'email'])} {self.c(['you', 'them', 'us', 'it'])}?"
        return f"{self.c(LABEL_HEADS)} {self.c(LABEL_NOUNS)}"

    def title(self):
        if self.p(0.5):
            return self.c(["", "", "", "Senior ", "Junior ", "Lead ", "Head ", "Assistant ", "Chief ", "Staff "]) + self.c(OCCUPATIONS)
        return self.c(["", "", "Senior ", "Junior ", "Principal ", "Associate "]) + self.c(DEPARTMENTS) + " " + self.c(ROLES)

    def org(self):
        name = self.c(ORG_FORMS).format(a=self.surname(), b=self.surname(), f=self.given())
        return self.c(["", "", "", "the "]) + name

    def thing(self):
        """A tool or product name: listed, or a dictionary word dressed up as one."""
        return self.c(self.tools) if self.p(0.5) else self.c(self.words).capitalize()

    def person(self):
        """A person as written: a list of (text, is_name) pieces."""
        first, last = self.given(), self.surname()
        style = self.r.random()
        if style < 0.06:
            return [(self.handle(), True)]
        if style < 0.30:
            pieces = [(first, True), (" ", False), (last, True)]
        elif style < 0.55:
            pieces = [(first, True)]
        elif style < 0.65:
            pieces = [(self.c(TITLES), False), (" ", False), (last, True)]
        elif style < 0.72:
            pieces = [(last, True)]
        elif style < 0.78:
            pieces = [(first, True), (" ", False)]
            for word in self.c(PARTICLES).split():
                pieces += [(word, True), (" ", False)]
            pieces.append((last, True))
        elif style < 0.84:
            family, given = self.c(FAMILY_FIRST)
            pieces = [(family, True)]
            for word in given.split():
                pieces += [(" ", False), (word, True)]
        elif style < 0.89:
            pieces = [(first, True), (" ", False), (self.c("ABCDEFGHJKLMNPRSTW") + ".", True), (" ", False), (last, True)]
        elif style < 0.93:
            pieces = [(last.upper(), True), (", ", False), (first.upper(), True)]
        elif style < 0.96:
            pieces = [(last, True), (", ", False), (first, True)]
        else:
            pieces = [(first, True), (" ", False), (last + "-" + self.surname(), True)]
        if self.p(0.12):
            pieces = self.lowered(pieces)
        return pieces

    def lowered(self, pieces):
        """Lowercased as in chat, except a name that is also a word ("hazel",
        "will"): written lowercase it is almost always the word."""
        if any(n and t in self.word_names for t, n in pieces):
            return pieces
        return [(t.lower(), n) for t, n in pieces]

    def plain_given(self):
        name = self.given()
        return name if name not in self.word_names else self.c(self.first)

    def handle(self):
        first = self.given().lower()
        last = self.surname().lower()
        form = self.c(["{f}.{l}", "{f}_{l}", "{fi}{l}", "{f}{li}", "{f}-{l}", "{f}{l}", "{f}.{l}{n}", "{fi}.{l}", "{l}.{f}", "{f}{n}"])
        return form.format(f=first, l=last, fi=first[0], li=last[0], n=self.r.randint(1, 99))

    def write(self, doc, pieces):
        for text, name in pieces:
            doc.add(text, name)

    def actor(self):
        """Someone who acts in a sentence: usually a person, sometimes a team, tool or bot."""
        roll = self.r.random()
        if roll < 0.62:
            return self.person()
        if roll < 0.70:
            return [(self.c(PRONOUNS), False)]
        if roll < 0.77:
            return [(self.c(["the ", "a ", "our ", "their ", "", ""]) + self.c(NOUNS) + self.c(["", "", " " + self.c(["eu-west", "42", "team", "account"])]), False)]
        if roll < 0.85:
            return [(self.c(NOT_PEOPLE_HANDLES), False)]
        if roll < 0.93:
            return [("the " + self.thing() + " " + self.c(["bot", "job", "service", "team", "pipeline", "integration"]), False)]
        return [(self.org(), False)]

    def free(self, doc):
        """A sentence with someone in subject, object or prepositional position."""
        verb = self.c(VERBS_PAST)
        obj = self.c(OBJECTS)
        prep = self.c(["with", "for", "to", "from", "by", "per", "via", "after", "behind", "and"])
        frame = self.r.randint(0, 5)
        lower = self.p(0.15)
        cased = lambda pieces: self.lowered(pieces) if lower else pieces
        if frame == 0:
            self.write(doc, cased(self.actor())); doc.add(f" {verb} {obj} {self.c(TAILS)}".rstrip())
        elif frame == 1:
            doc.add(f"{self.c(['We', 'They', 'Support', 'Finance', 'I'])} {verb} {obj} {prep} "); self.write(doc, cased(self.actor()))
        elif frame == 2:
            doc.add(f"{obj.capitalize()} {self.c(['is', 'was', 'got'])} {verb} {prep} "); self.write(doc, cased(self.actor())); doc.add(f" {self.c(TAILS)}".rstrip())
        elif frame == 3:
            doc.add(f"{self.c(['Reassigned', 'Moved', 'Handed over', 'Escalated', 'Transferred'])} {obj} from "); self.write(doc, cased(self.actor()))
            doc.add(" to "); self.write(doc, cased(self.actor()))
        elif frame == 4:
            self.write(doc, cased(self.actor())); doc.add(f" {self.c(['wants', 'needs', 'asked for', 'is waiting on', 'never got', 'keeps asking about'])} {obj}")
        else:
            doc.add(f"{self.c(['Called', 'Emailed', 'Texted', 'Messaged', 'Paged', 'Pinged'])} "); self.write(doc, cased(self.actor()))
            doc.add(f" {self.c(['back', 'again', 'twice', 'about it', 'first thing'])}{self.c([', ', '; ', ' - '])}{obj} {verb}")
        doc.add(self.c([".", ".", "", "!", "?"]))

    # Each segment appends a line or sentence to the document.
    def sentence(self, doc):
        who = self.person()
        form = self.r.randint(0, 9)
        if form == 0:
            self.write(doc, who); doc.add(f" {self.c(VERBS_PAST)} {self.c(OBJECTS)} {self.c(TAILS)}".rstrip() + ".")
        elif form == 1:
            doc.add(f"{self.c(OBJECTS).capitalize()} was {self.c(VERBS_PAST)} by "); self.write(doc, who); doc.add(".")
        elif form == 2:
            doc.add(self.c(["Spoke to ", "Talked with ", "Left a message for ", "Waiting on ", "Heard back from ", "Called "])); self.write(doc, who)
            doc.add(self.c([" about ", " re ", " regarding "]) + self.c(OBJECTS) + ".")
        elif form == 3:
            self.write(doc, who); doc.add("'s " + self.c(["laptop", "card", "address", "account", "manager", "flight", "parcel", "request"]) + " " + self.c(["is missing", "was updated", "needs a look", "expired", "arrived"]) + ".")
        elif form == 4:
            doc.add(self.c(["Per ", "According to ", "As ", "Thanks to "])); self.write(doc, who); doc.add(self.c([", ", " "]) + "the " + self.c(["totals", "dates", "numbers", "logs"]) + " " + self.c(["look fine", "are off", "need another pass"]) + ".")
        elif form == 5:
            doc.add(self.c(["can you ask ", "pls ping ", "loop in ", "check with ", "ask "])); self.write(doc, self.lowered(who)); doc.add(self.c([" about it", " when you can", "", " asap", " before eod"]))
        elif form == 6:
            self.write(doc, who); doc.add(self.c([" said ", " says ", " thinks ", " mentioned "]) + self.c(["the card was charged twice", "it never arrived", "the form is wrong", "we can close it", "the link is broken"]) + self.c([".", "", "!"]))
        elif form == 7:
            if self.p(0.5):
                # A role named with the thing it belongs to: "Record owner:", "Account manager -".
                role = self.c(["owner", "manager", "contact", "reviewer", "lead", "holder", "sponsor", "approver", "rep", "admin"])
                doc.add(f"{self.c(COMMON_CAPS + [w.capitalize() for w in NOUNS + FIELD_WORDS])} {role}{self.c([': ', ' - ', ' is ', ' = '])}")
            else:
                doc.add(self.c(["Assigned to ", "Owner: ", "Reviewer: ", "Approved by ", "Reported by ", "Contact: ", "Requested by "]))
            self.write(doc, who)
            if self.p(0.4):
                doc.add(self.c([", updated by ", ", reviewed by ", ", cc "]) + self.c(["support", "billing", "the team", "ops"]))
        elif form == 8:
            doc.add(self.c(["Meeting with ", "Lunch with ", "1:1 with ", "Interview: ", "Call w/ "])); self.write(doc, who); doc.add(self.c([" at 3pm", " on " + self.c(DAYS), "", " (" + self.c(MONTHS) + ")"]))
        else:
            doc.add(self.c(["Thank you, ", "Sorry ", "Congrats ", "Welcome back, ", "Good catch "])); self.write(doc, who); doc.add(self.c(["!", ".", ""]))

    def email(self, doc):
        who = self.person()
        greeting = self.c(["Hi ", "Hello ", "Hey ", "Dear ", "Good morning ", "Morning ", "Hiya ", "Afternoon ", "Attn: ", "To "])
        if self.p(0.2):
            greeting = greeting.lower()
        doc.add(greeting); self.write(doc, who); doc.add(self.c([",", ",", ":", " -", "!", ""]) + "\n" + self.c(["\n", ""]))
        doc.add(self.c(["Following up on your request.", "Attached is the updated quote.", "Your order is on its way.", "We could not verify the payment.", "The fix is live.", "Can you confirm the address?"]))
        doc.add("\n\n" + self.c(["Thanks,", "Best,", "Regards,", "Kind regards,", "Cheers,", "Thank you,", "All the best,", "Best regards,", "Many thanks,", "Sincerely,", "Ta,", "--"]) + "\n")
        signer = self.person() if self.p(0.7) else [(self.given(), True)]
        if self.p(0.15):
            doc.add(self.c(["— ", "- ", "~"]))
        self.write(doc, signer)
        if self.p(0.4):
            doc.add("\n" + self.c([self.title(), self.title(), "Head of Operations", self.org(), "Support Team", "Sent from my phone"]))

    def chat(self, doc):
        for _ in range(self.r.randint(2, 5)):
            stamp = f"[{self.r.randint(0, 23):02}:{self.r.randint(0, 59):02}] " if self.p(0.6) else ""
            doc.add(stamp)
            if self.p(0.2):
                doc.add(self.c(NOT_PEOPLE_HANDLES))
            elif self.p(0.5):
                doc.add(self.handle(), True)
            else:
                doc.add(self.plain_given().lower() if self.p(0.5) else self.given(), True)
            doc.add(self.c([": ", " > ", " - "]))
            if self.p(0.4):
                doc.add("@"); doc.add(self.handle(), True); doc.add(" ")
            doc.add(self.c(["can someone check the queue", "lgtm", "deploying now", "rolled back", "who owns this?", "on it", "ty", "still failing for me", "merged"]) + "\n")

    def log(self, doc):
        level = self.c(["INFO", "WARN", "DEBUG", "ERROR", "info", "level=info"])
        stamp = f"2026-{self.r.randint(1, 12):02}-{self.r.randint(1, 28):02}T{self.r.randint(0, 23):02}:{self.r.randint(0, 59):02}:{self.r.randint(0, 59):02}Z"
        doc.add(f"{stamp} {level} ")
        form = self.r.randint(0, 4)
        if form == 0:
            doc.add(self.c(["user=", "actor=", "by=", "owner=", "assignee="]))
            if self.p(0.25):
                doc.add(self.c(NOT_PEOPLE_HANDLES))
            else:
                doc.add(self.handle(), True)
            doc.add(f" action={self.c(['login', 'export', 'delete', 'update'])} status={self.r.randint(200, 503)}")
        elif form == 1:
            doc.add(self.c(["assigned ticket ", "closed ticket ", "reopened ticket "]) + str(self.r.randint(100, 99999)) + " to "); self.write(doc, self.person())
        elif form == 2:
            doc.add(self.c(["job ", "worker ", "task "]) + self.c(self.tools) + self.c([" finished", " failed", " retried", " started"]) + f" in {self.r.randint(1, 900)}ms")
        elif form == 3:
            doc.add("Signed-off-by: "); self.write(doc, self.person()[:3])
        else:
            doc.add(self.c(["TODO(", "FIXME(", "NOTE("])); doc.add(self.plain_given().lower() if self.p(0.5) else self.handle(), True); doc.add("): " + self.c(["drop the retry", "remove after migration", "flaky on ci"]))
        doc.add("\n")

    def roster(self, doc):
        doc.add(self.c(["cc: ", "Attendees: ", "Owners: ", "To: ", "Present: ", "Reviewers - "]))
        for i in range(self.r.randint(2, 4)):
            if i:
                doc.add(self.c([", ", "; ", " and ", " / "]))
            self.write(doc, self.person())

    def negative(self, doc):
        if self.prose and self.p(0.45):
            sentence = self.c(self.prose)
            doc.add(sentence.lower() if self.p(0.15) else sentence)
            return
        form = self.r.randint(0, 8)
        if form == 0:
            tool = self.thing()
            doc.add(self.c([f"The {tool} build failed on main.", f"Upgrade {tool} before the next deploy.", f"{tool} flagged the change.", f"We moved the job from {tool} to cron.",
                            f"Restart the {tool} cluster if latency spikes.", f"The {tool} dashboard shows no errors.", f"Ask {tool} to rerun the checks.", f"Written in {tool}."]))
        elif form == 1:
            org = self.org()
            doc.add(self.c([f"The wire came from {org}.", f"{org} confirmed the shipment.", f"We signed with {org} in {self.c(MONTHS)}.", f"Invoice addressed to {org}.", f"{org} reported strong earnings."]))
        elif form == 2:
            modifiers = [w.lower() for w in MODIFIER_NAMES if w in self.word_names]
            if modifiers and self.p(0.4):
                # Word-names used as plain modifiers: "the ivy and holly beds".
                a, b = self.c(modifiers), self.c(modifiers)
                noun = self.c(["hedges", "beds", "bushes", "plants", "tiles", "panels", "shelves", "samples", "swatches", "trim", "bottles", "boxes"])
                doc.add(self.c([f"the {a} and {b} {noun} were {self.c(['trimmed', 'restocked', 'moved', 'cleaned', 'replaced'])}", f"a {a} {noun} by the gate",
                                f"order more {a} {noun} and {b} {noun}", f"the {a} {noun} need water", f"{a}, {b} and {self.c(modifiers)} {noun} are in stock"]) + ".")
                return
            word = self.c([w for w, uses in self.word_names.items() if uses])
            use = self.c(self.word_names[word])
            doc.add(use[0].upper() + use[1:] + "." if self.p(0.5) else use + ".")
        elif form == 3:
            doc.add(self.c([f"Flying to {self.c(self.places)} on {self.c(DAYS)}.", f"The {self.c(self.places)} warehouse is closed.", f"Shipped from {self.c(self.places)}.", f"Moved the meeting to {self.c(DAYS)} in {self.c(MONTHS)}."]))
        elif form == 4:
            doc.add(" ".join(self.c(COMMON_CAPS) for _ in range(self.r.randint(1, 4))) + self.c([":", "", " -", "\n"]))
        elif form == 5:
            doc.add(self.c(["user_id", "first_name", "last.updated", "account.owner", "billing_contact", "self.name", "user.email", "order_id"]) + self.c([" = ", ": ", "="]) + self.c(["null", "None", str(self.r.randint(1, 9999)), "true"]))
        elif form == 6:
            doc.add(f"{self.c(COMMON_CAPS)} {self.c(VERBS_PAST)} {self.c(TAILS)}".rstrip() + ".")
        elif form == 7:
            doc.add(f"The {self.thing()} {self.c(['panel', 'plugin', 'cluster', 'module', 'library', 'release', 'runner', 'node', 'connector'])} {self.c(['is down', 'shows a spike', 'was upgraded', 'could not start', 'needs a restart'])}.")
        else:
            word = self.c([w for w, uses in self.word_names.items() if uses])
            doc.add(self.c(["We ", "They ", "You "]) + self.c(self.word_names[word]) + ".")

    def identifier(self):
        """Keys, IDs, code names and the like: never a person, however they are built."""
        w = lambda: self.c(self.words)
        n = lambda: str(self.r.randint(0, 99999))
        alnum = lambda k: "".join(self.c("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") for _ in range(k))
        form = self.r.randint(0, 15)
        return [
            lambda: f"{self.c(FIELD_WORDS)}{self.c(['', '_', '-'])}{self.r.randint(1, 12)}", lambda: f"{self.c(FIELD_WORDS)}{self.c(FIELD_WORDS).capitalize()}{self.c(['', '2', 'Id'])}",
            lambda: f"{w()}_{w()}", lambda: f"{w()}-{w()}", lambda: f"{w()}{w().capitalize()}", lambda: f"{w()[0]}_{n()}",
            lambda: f"{self.c(['sk_live_', 'pk_test_', 'ghp_', 'xoxb-', 'AKIA', 'tok_', 'key_'])}{alnum(self.r.randint(12, 28))}",
            lambda: f"{self.c(['@SUM', '=SUM', '+CMD', '-HYPERLINK', '@IF'])}({self.c('ABCDE')}{self.r.randint(1, 99)})",
            lambda: f"{w()}.{self.c(['csv', 'json', 'pdf', 'log', 'txt', 'xlsx'])}", lambda: f"{self.c(['api', 'db', 'cdn', 'mail'])}.{w()}.{self.c(['io', 'com', 'net'])}",
            lambda: f"{w().upper()}_{w().upper()}", lambda: f"v{self.r.randint(0, 9)}.{self.r.randint(0, 20)}.{self.r.randint(0, 99)}",
            lambda: f"{self.c(['u', 'usr', 'acct', 'ord', 'inv', 'cus', 'txn'])}_{alnum(self.r.randint(4, 14))}", lambda: f"{w()}-{self.c(['team', 'bot', 'service', 'prod', 'eu-west', 'v2'])}",
            lambda: f"self.{w()}_{w()}", lambda: f"{w()}.{w()}({w()})",
        ][form]()

    def address(self):
        """A street address or city line: never a person, though its words often look like names."""
        street = f"{self.r.randint(1, 9999)} {self.c(self.words).capitalize()}{self.c(['', ' ' + self.c(self.words).capitalize()])} {self.c(STREET_TYPES)}"
        city = self.c(self.places) if self.p(0.5) else self.c(self.words).capitalize()
        line = f"{city}, {self.c(CODES[:16])} {self.r.randint(10000, 99999)}{self.c(['', '-' + str(self.r.randint(1000, 9999))])}"
        return self.c([street, line, f"{street}, {line}", f"{street}\n{self.c(['Apt', 'Suite', 'Unit'])} {self.r.randint(1, 40)}{self.c('ABCD')}\n{line}"])

    def mailing(self, doc):
        doc.add(self.c(["Ship to: ", "Bill to: ", "Attn: ", "", "Deliver to "]))
        self.write(doc, self.person())
        doc.add(self.c(["\n", ", "]) + self.address())

    def keyvalue(self, doc):
        """Lines of settings or code: a value is a person only under a key that names one."""
        style = self.r.randint(0, 7)
        casing = self.r.randint(0, 3)
        indent = self.c(["", "  ", "    ", "        "])
        for i in range(self.r.randint(1, 6)):
            person, titled, labelled = self.p(0.3), self.p(0.15), self.p(0.15)
            key = self.c(PERSON_KEYS) if person else self.c(TITLE_KEYS) if titled else self.c(["label", "placeholder", "hint", "prompt", "question", "description"]) if labelled else self.c(ENUM_KEYS + FIELD_WORDS)
            key = self.cased(key, casing)
            end = "\n" if i else self.c(["\n", " "])
            if style == 0:
                doc.add(f'  "{key}": "'); end = '",\n'
            elif style == 1:
                doc.add(f"{key}: ")
            elif style == 2:
                doc.add(f"{key}=")
            elif style == 3:
                doc.add(f"{self.c(['user', 'employee', 'record', 'config', 'data'])}.{key} = ")
            elif style == 4:
                doc.add(f"- {key}: ")
            elif style == 5:
                doc.add(f"{key} = ")
            else:
                # A JavaScript or Python object literal.
                quote = "'" if style == 6 else '"'
                doc.add(f"{indent}{key}: {quote}"); end = f"{quote},\n"
            if person:
                self.write(doc, self.person())
            elif titled:
                doc.add(self.title())
            elif labelled:
                doc.add(self.label())
            else:
                value = self.c(ENUM_VALUES) if self.p(0.6) else self.c(STATUS_VALUES) if self.p(0.5) else self.c(self.words)
                doc.add(value)
            doc.add(end)

    @staticmethod
    def cased(key, casing):
        """first_name as written by different codebases: first_name, FirstName, FIRST_NAME, firstName."""
        parts = [p for p in re.split(r"[_\-]", key) if p]
        if casing == 1:
            return "".join(p.capitalize() for p in parts)
        if casing == 2:
            return "_".join(p.upper() for p in parts)
        if casing == 3:
            return parts[0] + "".join(p.capitalize() for p in parts[1:])
        return key

    def foreign(self, doc):
        if self.p(0.3):
            doc.add(self.c(FOREIGN_PLAIN))
            return
        before, after = self.c(FOREIGN).replace("{place}", self.c(self.places)).replace("{month}", self.c(MONTHS).lower()).split("{p}")
        doc.add(before); self.write(doc, self.person()); doc.add(after)

    def code(self, doc):
        """Source code: field names and types are not people; a string literal can hold one."""
        w = lambda: self.c(self.words)
        camel = lambda: w() + w().capitalize()
        kind = self.r.randint(0, 3)
        if kind == 0:
            doc.add(f"interface {w().capitalize()} {{\n")
            for _ in range(self.r.randint(1, 4)):
                doc.add(f"  {self.c([camel(), 'firstName', 'lastName', 'email', 'name', 'owner'])}: {self.c(['string', 'number', 'boolean', 'Date', 'string[]'])};\n")
            doc.add("}")
        elif kind == 1:
            doc.add(f"const {w()} = {{ {camel()}: {w()}.{camel()}, {w()}: {w()}.{w()}, name: '"); self.write(doc, self.person()); doc.add("' };")
        elif kind == 2:
            doc.add(f"def {w()}_{w()}(self, {w()}):\n    return self.{w()}.get('{w()}')")
        else:
            doc.add(f"{self.c(['SELECT', 'select'])} {w()}_id, {w()} FROM {w()}s WHERE {w()} = '"); self.write(doc, self.person()); doc.add("';")

    def field(self, doc):
        """A short value with nothing around it, the way it sits in a JSON or CSV cell."""
        roll = self.r.random()
        if roll < 0.35:
            self.write(doc, self.person())
        elif roll < 0.55:
            doc.add(self.identifier())
        elif roll < 0.65:
            doc.add(" ".join(self.c(self.words).capitalize() for _ in range(self.r.randint(1, 2))) + " " + self.c(SUFFIXES + ["Team", "Pro", "Plus", "Report", "Desk", "Ops", "Platform"]))
        elif roll < 0.8:
            text = " ".join(self.c(self.words) for _ in range(self.r.randint(1, 4)))
            doc.add(text.title() if self.p(0.4) else text)
        elif roll < 0.83:
            doc.add(self.label())
        elif roll < 0.86:
            doc.add(self.c(COMMON_CAPS + self.tools + [self.org()] * 10 + MONTHS + DAYS + self.places))
        elif roll < 0.9:
            doc.add(self.c(CODES) if self.p(0.6) else self.address())
        else:
            doc.add(self.c(OBJECTS).capitalize() + " " + self.c(VERBS_PAST))

    def document(self):
        doc = Doc()
        kind = self.r.random()
        if kind < 0.15:
            self.field(doc)
            return doc
        if kind < 0.17:
            self.foreign(doc)
            return doc
        if self.p(0.08):
            self.keyvalue(doc)
            return doc
        if kind < 0.19:
            self.code(doc)
            return doc
        if kind < 0.22:
            self.sentence(doc)
            doc.add(" " + self.c(STARTERS) + self.c([", ", " ", ": "]))
            self.write(doc, self.lowered(self.person()) if self.p(0.3) else self.person())
            doc.add(" " + self.c(["replied", "called back", "agreed", "said no", "followed up"]) + ".")
            return doc
        if kind < 0.35:
            self.email(doc)
        elif kind < 0.43:
            self.chat(doc)
        elif kind < 0.52:
            for _ in range(self.r.randint(1, 3)):
                self.log(doc)
        else:
            for i in range(self.r.randint(1, 4)):
                if i:
                    doc.add(self.c([" ", " ", "\n", "\n\n"]))
                choice = self.r.random()
                if choice < 0.3:
                    self.sentence(doc)
                elif choice < 0.55:
                    self.free(doc)
                elif choice < 0.63:
                    self.roster(doc)
                elif choice < 0.7:
                    doc.add(self.c(STARTERS) + self.c([", ", " "]) + self.c(OBJECTS) + " " + self.c(VERBS_PAST) + ".")
                elif choice < 0.73:
                    doc.add(self.identifier())
                elif choice < 0.77:
                    self.mailing(doc)
                elif choice < 0.8:
                    doc.add(f"{self.c(['Flying to', 'Shipped from', 'Office in', 'Moved to'])} {self.address().replace(chr(10), ', ')}.")
                else:
                    self.negative(doc)
        return doc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=150000)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--prose", help="sentences with no people in them, one per line (extract_prose.py)")
    args = parser.parse_args()
    prose = open(args.prose).read().splitlines() if args.prose else []
    gen = Gen(args.seed, held_out_vocabulary(), prose)
    for _ in range(args.count):
        doc = gen.document()
        print(json.dumps({"text": doc.text(), "spans": doc.spans}, ensure_ascii=False))


if __name__ == "__main__":
    main()
