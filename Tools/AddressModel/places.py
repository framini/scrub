"""Address parts for the generator: real localities and postcodes per country
(GeoNames postal code files, CC BY 4.0), US street names (US Census TIGER/Line
FEATNAMES, public domain), and hand-written street words per language.

Every list is split in two by a stable hash: the held-out half (one in ten)
only ever appears in the held-out test set, never in training.
"""
import collections
import hashlib
import os
import random
import re

HERE = os.path.dirname(os.path.abspath(__file__))
GEONAMES = os.environ.get("ADDRESS_GEONAMES", os.path.join(HERE, "raw", "geonames"))
STREETS = os.environ.get("ADDRESS_US_STREETS", os.path.join(HERE, "data", "us_streets.tsv"))
NAME_LISTS = os.environ.get("ADDRESS_NAME_LISTS", os.path.join(HERE, "..", "..", "Sources", "ScrubCore", "Resources", "NameLists.txt"))


def held_out(value):
    """One value in ten belongs to the held-out test set."""
    return hashlib.sha1(value.lower().encode()).digest()[0] % 10 == 0


def keep(values, holdout):
    return [v for v in values if held_out(v) == holdout]


Locality = collections.namedtuple("Locality", "country postal place region region_code county")

COUNTRIES = ["US", "CA", "GB", "AU", "NZ", "IE", "DE", "FR", "NL", "BE", "ES", "IT", "PT", "AT", "CH", "SE", "DK", "NO", "FI", "PL", "CZ",
             "IN", "SG", "ZA", "MX", "BR", "JP"]


def load_localities(holdout, firms=False):
    """Real localities by country. Germany's file also names firms and offices
    with a postcode of their own; they are left out unless `firms` (the first
    model's data kept them)."""
    found = {}
    for country in COUNTRIES:
        rows = []
        path = os.path.join(GEONAMES, country + ".txt")
        for line in open(path, encoding="utf-8"):
            f = line.rstrip("\n").split("\t")
            postal, place = f[1], f[2]
            # Court and P.O. box entries in some files are not places.
            if not place or re.search(r"(?i)gericht|postfach|cedex|\bbox\b|\bbag\b|\(|\d", place) or len(place) > 32:
                continue
            if "CEDEX" in postal:
                continue
            # Germany's file also names the firms and offices with a postcode of their own
            # ("… Versicherung AG", "Stadtverwaltung"); those rows have no accuracy.
            if country == "DE" and not firms and (len(f) < 12 or not f[11].strip()):
                continue
            if country == "DE" and not firms and re.search(r"(?i)\b(?:gmbh|mbh|ag|kg|se|e\.\s?v|co|services?|insurance|versicherung\w*|bank|verlag|vertrieb\w*|werk\w*|presse|stiftung|bundes\w*|amt|zentrale|deutsche|universität|klinik\w*)\b|\.\s|\bder\b|\bdes\b|\bund\b", place):
                continue
            if held_out(place) != holdout:
                continue
            rows.append(Locality(country, postal, place, f[3], f[4], f[5]))
        found[country] = rows
    return found


def load_us_streets(holdout):
    streets = []
    for line in open(STREETS, encoding="utf-8"):
        pd, pt, name, st, sd = line.rstrip("\n").split("\t")
        if held_out(name) != holdout:
            continue
        if not (st or pt):
            continue
        if name.isdigit() and not pt:
            continue
        streets.append((pd, pt, name, st, sd))
    return streets


def load_names(holdout):
    first, last, words, section = [], [], [], None
    for line in open(NAME_LISTS, encoding="utf-8"):
        line = line.strip()
        if line.startswith("["):
            section = line.strip("[]")
            continue
        if not line or line.startswith("#"):
            continue
        if section == "first":
            first.append(line.capitalize())
        elif section == "surname":
            last.append(line.capitalize())
        elif section == "ordinary" and line.isalpha() and 4 <= len(line) <= 9:
            words.append(line)
    return keep(first, holdout), keep(last, holdout), words


# Hand-written street words. Generic words are shared by both halves; only
# proper names (surnames and places) are split.
GB_WORDS = """Mill Church Station High Park Victoria Queen's King's Albert Manor Orchard Meadow Willow Oak Elm Chapel Bridge School Green North South
West East Grange Hollow Beech Birch Cedar Holly Rowan Ash Hazel Maple Abbey Priory Castle Market Kingsway Westfield Fairfield Springfield Newlands
Highfield Moorland Riverside Brook Ferry Harbour Quarry Forge Common Heath Wood Copse Field Lark Swallow Robin Primrose Bluebell Heather Lavender
Cherry Plum Vicarage Rectory Glebe Pound Well Spring Water Sandy Stony Long Broad Narrow Upper Lower Middle New Old St John's St Mary's Princess""".split()
GB_TYPES = ["Road", "Street", "Lane", "Avenue", "Close", "Crescent", "Drive", "Gardens", "Grove", "Place", "Terrace", "Way", "Walk", "Mews", "Rise",
            "Row", "Square", "Hill", "Court", "View", "Park", "Green", "Vale", "Parade", "Fields", "Meadows", "Gate", "End", "Chase", "Wharf"]
GB_BUILDINGS = ["House", "Court", "Lodge", "Cottage", "Mansions", "Building", "Point", "Tower", "Hall", "Barn", "Farm", "Works", "Mill", "Place", "Wharf"]
AU_TYPES = [("Street", "St"), ("Road", "Rd"), ("Avenue", "Ave"), ("Parade", "Pde"), ("Crescent", "Cres"), ("Place", "Pl"), ("Drive", "Dr"),
            ("Highway", "Hwy"), ("Terrace", "Tce"), ("Close", "Cl"), ("Court", "Ct"), ("Lane", "La"), ("Way", "Way"), ("Circuit", "Cct"),
            ("Boulevard", "Bvd"), ("Grove", "Gr"), ("Esplanade", "Esp")]
NZ_TYPES = ["Street", "Road", "Avenue", "Terrace", "Place", "Crescent", "Drive", "Lane", "Grove", "Way", "Rise", "Quay"]
US_EXPAND = {"St": "Street", "Ave": "Avenue", "Rd": "Road", "Dr": "Drive", "Ln": "Lane", "Ct": "Court", "Blvd": "Boulevard", "Pkwy": "Parkway",
             "Hwy": "Highway", "Trl": "Trail", "Cir": "Circle", "Pl": "Place", "Ter": "Terrace", "Sq": "Square", "Pike": "Pike", "Way": "Way"}
US_DIRS = {"N": "North", "S": "South", "E": "East", "W": "West", "NE": "Northeast", "NW": "Northwest", "SE": "Southeast", "SW": "Southwest"}
US_STATES = """AL Alabama|AK Alaska|AZ Arizona|AR Arkansas|CA California|CO Colorado|CT Connecticut|DE Delaware|DC District of Columbia|FL Florida|GA Georgia|HI Hawaii|ID Idaho|IL Illinois|IN Indiana|IA Iowa|KS Kansas|KY Kentucky|LA Louisiana|ME Maine|MD Maryland|MA Massachusetts|MI Michigan|MN Minnesota|MS Mississippi|MO Missouri|MT Montana|NE Nebraska|NV Nevada|NH New Hampshire|NJ New Jersey|NM New Mexico|NY New York|NC North Carolina|ND North Dakota|OH Ohio|OK Oklahoma|OR Oregon|PA Pennsylvania|RI Rhode Island|SC South Carolina|SD South Dakota|TN Tennessee|TX Texas|UT Utah|VT Vermont|VA Virginia|WA Washington|WV West Virginia|WI Wisconsin|WY Wyoming|PR Puerto Rico"""
CA_PROVINCES = {"AB": "Alberta", "BC": "British Columbia", "MB": "Manitoba", "NB": "New Brunswick", "NL": "Newfoundland and Labrador",
                "NS": "Nova Scotia", "NT": "Northwest Territories", "NU": "Nunavut", "ON": "Ontario", "PE": "Prince Edward Island", "QC": "Quebec",
                "SK": "Saskatchewan", "YT": "Yukon"}
DE_WORDS = """Haupt Bahnhof Kirch Schul Garten Berg Wald Linden Eichen Birken Buchen Rosen Mühlen Wiesen Feld Dorf Markt Burg Schloss Brunnen Tal
Bach Sonnen Mond Stern Ring Post Kloster Friedhof Wein Hafen Brücken Tor Turm Bergmann Goethe Schiller Mozart Beethoven Kant Lessing Herder Uhland
Industrie Gewerbe Ahorn Erlen Tannen Fichten Kastanien Ulmen Weiden Hasel Holunder Lerchen Amsel Finken Drossel Kreuz Graben Anger Hof Hohe""".split()
DE_TYPES = ["straße", "str.", "weg", "gasse", "platz", "allee", "ring", "damm", "ufer", "steig", "pfad", "chaussee"]
FR_TYPES = ["rue", "avenue", "boulevard", "place", "allée", "impasse", "chemin", "quai", "route", "cours", "passage", "square", "rue", "rue", "avenue"]
FR_LINK = ["de la", "du", "des", "de l'", "de", "", "", "Saint-", "Sainte-"]
FR_WORDS = """Paix Gare Église République Liberté Fontaine Moulin Château Marché Poste Mairie Pont Lilas Roses Tilleuls Peupliers Chênes Vignes
Écoles Jardins Prés Champs Bois Forêt Rivière Source Croix Lavoir Four Calvaire Victor-Hugo Jean-Jaurès Pasteur Voltaire Gambetta Foch
Clemenceau Général-de-Gaulle Verdun Hôtel-de-Ville Commerce Industrie Bretagne Normandie Provence Lorraine Alsace Faubourg Mont Belvédère""".split()
NL_WORDS = """Kerk Molen School Dorps Heren Keizers Prinsen Linden Eiken Beuken Berken Wilgen Rozen Tulpen Lelie Nieuwe Oude Hoog Laan Markt Haven
Station Burg Slot Veld Weide Bos Duin Zee Rijn Maas Wester Ooster Noorder Zuider Spoor Brug Sluis Vaart Gracht Singel Hof Akker Beek""".split()
NL_TYPES = ["straat", "laan", "weg", "gracht", "plein", "kade", "singel", "dijk", "steeg", "hof", "pad", "dreef"]
ES_TYPES = ["Calle", "C/", "Avenida", "Avda.", "Av.", "Plaza", "Pza.", "Paseo", "Camino", "Ronda", "Travesía", "Carrera", "Calle"]
ES_WORDS = """Mayor Real Nueva Iglesia Sol Luna Rosales Olivos Pinos Molino Fuente Castillo Mercado Constitución Libertad Paz Colón Cervantes
Goya Velázquez Alcalá Princesa Reyes Católicos San Francisco San Juan Santa María Doctor Fleming Andalucía Castilla Valencia Cataluña Huertas
Almendros Naranjos Jazmines Gran Vía Diagonal Marina Puerto Estación Ermita Cruz Hospital Toledo Segovia""".split("\n")
ES_WORDS = [w for line in ES_WORDS for w in line.split()]
IT_TYPES = ["Via", "Viale", "Piazza", "Corso", "Largo", "Vicolo", "Strada", "Via", "Via", "Piazzale", "Lungomare", "Contrada"]
IT_WORDS = """Roma Garibaldi Mazzini Cavour Dante Verdi Marconi Matteotti Gramsci Manzoni Leopardi Venezia Milano Torino Nazionale Vittorio Emanuele
Umberto Repubblica Libertà Indipendenza Duomo Castello Mercato Fontana Chiesa Stazione Ospedale Mulino Giardini Pini Tigli Ulivi Rose Sole Mare
Monte Colle Porta Ponte Fiume Lago Borgo Santa Lucia San Marco San Giovanni""".split()
PT_TYPES = ["Rua", "Avenida", "Av.", "Travessa", "Largo", "Praça", "Estrada", "Alameda", "Rua", "Rua", "Beco", "Calçada"]
PT_WORDS = """Augusta Liberdade República Flores Comércio Prata Ouro Sol Mar Rosas Oliveiras Pinheiros Moinho Fonte Igreja Castelo Mercado Estação
Escola Paz Bom Jesus Santo António São João Nossa Senhora Dom Pedro Infante Camões Garrett Almirante Reis Brasil Portugal Lisboa Porto Paulista
Ipiranga Atlântica Vergueiro Consolação Bela Vista Jardim""".split()
SE_TYPES = ["gatan", "vägen", "gränd", "torget", "stigen", "backen", "allén", "plan"]
SE_WORDS = """Kyrko Skol Drottning Kungs Stor Lill Strand Hamn Kvarn Bruks Ängs Skogs Björk Ek Lind Gran Tall Rosen Sjö Berg Dal Sol Norr Söder Väster
Öster Fabriks Järnvägs Torg Park Bergs Lärk Hägg Vall Gärdes""".split()
DK_TYPES = ["gade", "vej", "allé", "stræde", "plads", "torv", "vænget", "parken"]
NO_TYPES = [" gate", "veien", "vegen", " vei", "gata", " plass", "bakken", "stien"]
FI_TYPES = ["katu", "tie", "kuja", "polku", "tori", "puistikko", "rinne", "ranta"]
FI_WORDS = """Mannerheimin Aleksanterin Kauppa Koulu Kirkko Asema Satama Puisto Mäki Järvi Ranta Koivu Kuusi Mänty Pihlaja Tammi Vaahtera Kivi Sauna
Hämeen Turun Helsingin Tampereen Itä Länsi Pohjois Etelä Kalevan Runeberg""".split()
PL_TYPES = ["ul.", "al.", "pl.", "os.", "ulica", "Aleja", "ul.", ""]
PL_WORDS = """Marszałkowska Mickiewicza Słowackiego Kościuszki Piłsudskiego Sienkiewicza Kopernika Chopina Długa Krótka Polna Leśna Ogrodowa Kwiatowa
Szkolna Kościelna Lipowa Brzozowa Słoneczna Spacerowa Rynek Grunwaldzka Jagiellońska Warszawska Krakowska Poznańska Wolności Pokoju Zielona
Nowa Stara Mostowa Wodna Piękna""".split()
CZ_WORDS = """Václavské náměstí|Národní|Vinohradská|Masarykova|Husova|Palackého|Jungmannova|Komenského|Školní|Nádražní|Zahradní|Lipová|Krátká|Dlouhá|Polní|Lesní|Nová|Riegrova|Smetanova|Tylova|Revoluční|Na Příkopě|U Lesa|Sokolská|Žižkova""".split("|")
IN_WORDS = """MG Road|Brigade Road|Residency Road|Park Street|Linking Road|Hill Road|Station Road|Temple Road|Church Street|Nehru Road|Gandhi Nagar|Anna Salai|Ring Road|Sector 18|Main Road|Cross Road|Nagar Road|Lake View Road|College Road|Market Road|Sarojini Marg|Tilak Marg|Rajpath""".split("|")
IN_BUILDINGS = ["Apartments", "Residency", "Towers", "Enclave", "Heights", "Complex", "Plaza", "Chambers", "Bhavan", "Niwas"]
SG_WORDS = """Ang Mo Kio|Bedok North|Tampines|Jurong West|Toa Payoh|Yishun|Clementi|Bukit Batok|Hougang|Serangoon|Pasir Ris|Woodlands|Sengkang|Punggol|Bishan|Choa Chu Kang""".split("|")
SG_ROADS = """Orchard Road|Bukit Timah Road|Cecil Street|Robinson Road|Shenton Way|Raffles Place|Beach Road|North Bridge Road|Marine Parade Road|Holland Road|Dunearn Road|Thomson Road|Upper Serangoon Road|Jalan Besar|Tanjong Pagar Road""".split("|")
SG_BUILDINGS = ["Tower", "Centre", "Building", "Plaza", "Point", "Hub", "House", "Court", "Residences", "Suites"]
JP_WARDS = ["Shibuya-ku", "Shinjuku-ku", "Minato-ku", "Chuo-ku", "Chiyoda-ku", "Setagaya-ku", "Meguro-ku", "Kita-ku", "Naka-ku", "Higashi-ku",
            "Nishi-ku", "Minami-ku", "Sakyo-ku", "Nakagyo-ku", "Toshima-ku", "Taito-ku", "Bunkyo-ku", "Koto-ku"]
JP_CITIES = ["Tokyo", "Osaka", "Kyoto", "Yokohama", "Nagoya", "Sapporo", "Fukuoka", "Kobe", "Sendai", "Hiroshima"]
BR_UF = ["SP", "RJ", "MG", "RS", "PR", "SC", "BA", "PE", "CE", "DF", "GO", "PA", "AM", "ES"]
MX_WORDS = """Reforma|Insurgentes Sur|Juárez|Hidalgo|Morelos|Madero|5 de Mayo|16 de Septiembre|Benito Juárez|Revolución|Independencia|Constitución|Zaragoza|Allende|Guerrero|Álvaro Obregón|Universidad|Chapultepec|Patriotismo|Durango|Ámsterdam|Colima""".split("|")
MX_COLONIAS = ["Centro", "Roma Norte", "Condesa", "Juárez", "Del Valle", "Polanco", "Narvarte", "Doctores", "Obrera", "Escandón", "Moderna",
               "Las Águilas", "Jardines del Sur", "Lomas Verdes", "San Rafael", "Santa María la Ribera", "Americana", "Providencia"]
ZA_TYPES = ["Street", "Road", "Avenue", "Drive", "Crescent", "Lane", "Close", "Way"]

# Numberless addresses: house names, counties and the ways a street is named
# without a number ("Hauptstraße, Berlin-Mitte", "rue des Lilas, Nantes").
HOUSE_NAMES = ["The Old Rectory", "The Old Vicarage", "The Old School House", "The Old Forge", "The Coach House", "The Granary", "The Barn", "The Stables",
               "The Old Post Office", "The Old Bakery", "The Mill House", "The Lodge", "The Cottage", "The Manse", "The Old Chapel", "The Malthouse",
               "Orchard House", "Meadow View", "Hill Top", "Brook Cottage", "Ivy Cottage", "Holly Lodge", "Beech House", "Yew Tree Cottage", "Pear Tree House",
               "Wren Cottage", "Larch Lodge", "Glebe House", "Primrose Cottage", "Ashdown", "Fernlea", "Rosebank", "Woodside", "Hillcrest", "Briar Cottage"]
HOUSE_KINDS = ["Cottage", "House", "Lodge", "Farm", "Barn", "Manor", "Grange", "Mill", "Hall", "Croft", "End", "View", "Court", "Mews", "Place"]
GB_COUNTIES = ["Oxfordshire", "Warwickshire", "Gloucestershire", "Hertfordshire", "Buckinghamshire", "Wiltshire", "Somerset", "Dorset", "Devon", "Cornwall",
               "Cumbria", "Essex", "Kent", "Surrey", "Suffolk", "Norfolk", "Shropshire", "Herefordshire", "Worcestershire", "Lincolnshire", "North Yorkshire",
               "East Sussex", "West Sussex", "Hampshire", "Cambridgeshire", "Northumberland", "Derbyshire", "Powys", "Gwynedd", "Aberdeenshire", "Perthshire",
               "Fife", "Argyll", "County Durham", "Lancashire", "Cheshire", "Staffordshire", "Leicestershire", "Rutland", "Berkshire"]
IE_COUNTIES = ["Cork", "Kerry", "Galway", "Mayo", "Clare", "Wicklow", "Kildare", "Meath", "Donegal", "Sligo", "Tipperary", "Limerick", "Wexford", "Leitrim",
               "Roscommon", "Offaly", "Laois", "Cavan", "Monaghan", "Waterford", "Kilkenny", "Carlow", "Longford", "Westmeath", "Louth"]
DISTRICTS = {"DE": ["Mitte", "Nord", "Süd", "Ost", "West", "Altstadt", "Neustadt", "Innenstadt"], "AT": ["Innere Stadt", "Landstraße", "Favoriten"],
             "CH": ["Altstadt", "Oerlikon", "Wiedikon"], "FR": ["Centre", "Vieux Port"], "IT": ["Centro", "Centro Storico"], "ES": ["Centro"],
             "PT": ["Baixa", "Centro"], "NL": ["Centrum", "Oost", "West", "Noord", "Zuid"], "SE": ["Centrum", "Södermalm"]}
