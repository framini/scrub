"""Postal addresses in each country's own format, as lists of lines.

`Addresses(rng, holdout).make()` returns an `Address`: its lines (each a
list of comma-separated pieces) and the ways it may be written. Every part
is drawn from real localities and street words; numbers are random, so no
address is anyone's.
"""
import random
import string

from places import *  # noqa: F401,F403


class Address:
    def __init__(self, lines, country, kind="full"):
        self.lines = [[p for p in line if p] for line in lines]
        self.lines = [l for l in self.lines if l]
        self.country = country
        # full: street and locality; street: a street line only; locality: city and postcode only; box: a post office box
        self.kind = kind

    def multi(self, rng):
        return "\n".join(", ".join(line) for line in self.lines)

    def one(self, rng):
        sep = rng.choice([", "] * 12 + [" ", "; ", " - ", " · ", "  "])
        text = sep.join(", ".join(line) for line in self.lines)
        return text


def digits(rng, n):
    return "".join(rng.choice(string.digits) for _ in range(n))


def letters(rng, n, pool=string.ascii_uppercase):
    return "".join(rng.choice(pool) for _ in range(n))


def house(rng, low=1, high=9999):
    r = rng.random()
    if r < 0.45:
        n = rng.randint(1, 99)
    elif r < 0.75:
        n = rng.randint(100, 999)
    elif r < 0.95:
        n = rng.randint(1000, 9999)
    else:
        n = rng.randint(10000, 99999)
    return str(max(low, min(n, high)))


class Addresses:
    def __init__(self, rng, holdout=False):
        self.rng = rng
        self.holdout = holdout
        self.loc = load_localities(holdout)
        self.us_streets = load_us_streets(holdout)
        self.first, self.last, self.words = load_names(holdout)
        self.states = {s.split(" ", 1)[0]: s.split(" ", 1)[1] for s in US_STATES.split("|")}
        weights = {"US": 26, "GB": 14, "CA": 8, "AU": 8, "NZ": 3, "IE": 3, "DE": 5, "FR": 5, "NL": 3, "BE": 2, "ES": 3, "IT": 3, "PT": 2,
                   "AT": 2, "CH": 2, "SE": 2, "DK": 1, "NO": 1, "FI": 1, "PL": 2, "CZ": 1, "IN": 2, "SG": 1, "ZA": 1, "MX": 2, "BR": 2, "JP": 1}
        self.countries = list(weights)
        self.weights = [weights[c] for c in self.countries]

    # helpers
    def pick(self, seq):
        return self.rng.choice(seq)

    def chance(self, p):
        return self.rng.random() < p

    def place(self, country):
        return self.pick(self.loc[country])

    def stem(self, pool):
        """A street's proper name: a generic word, a surname or a place."""
        r = self.rng.random()
        if r < 0.55:
            return self.pick(pool)
        if r < 0.85:
            return self.pick(self.last)
        return self.pick(self.loc[self.pick(self.countries)]).place.split()[0].split("-")[0]

    def country_name(self, country):
        names = {"US": ["USA", "United States", "U.S.A.", "US"], "CA": ["Canada", "CANADA"], "GB": ["United Kingdom", "UK", "England", "Scotland", "Wales"],
                 "AU": ["Australia", "AUSTRALIA"], "NZ": ["New Zealand", "NZ"], "IE": ["Ireland", "Éire"], "DE": ["Germany", "Deutschland", "DE"],
                 "FR": ["France", "FRANCE"], "NL": ["Netherlands", "The Netherlands", "Nederland"], "BE": ["Belgium", "Belgique", "België"],
                 "ES": ["Spain", "España"], "IT": ["Italy", "Italia"], "PT": ["Portugal"], "AT": ["Austria", "Österreich"], "CH": ["Switzerland", "Schweiz", "Suisse"],
                 "SE": ["Sweden", "Sverige"], "DK": ["Denmark", "Danmark"], "NO": ["Norway", "Norge"], "FI": ["Finland", "Suomi"], "PL": ["Poland", "Polska"],
                 "CZ": ["Czech Republic", "Czechia"], "IN": ["India"], "SG": ["Singapore"], "ZA": ["South Africa"], "MX": ["Mexico", "México"],
                 "BR": ["Brazil", "Brasil"], "JP": ["Japan"]}
        return self.pick(names[country])

    def make(self, country=None):
        country = country or self.rng.choices(self.countries, self.weights)[0]
        address = getattr(self, "make_" + country.lower())()
        if address.kind == "full" and country not in ("SG",) and self.chance(0.18):
            address.lines.append([self.country_name(country)])
        return address

    # -- North America
    def us_street(self, caps=False):
        pd, pt, name, st, sd = self.pick(self.us_streets)
        if self.chance(0.4):
            st = US_EXPAND.get(st, st)
        elif st and self.chance(0.15):
            st += "."
        if pd and self.chance(0.3):
            pd = US_DIRS.get(pd, pd)
        elif pd and self.chance(0.2):
            pd += "."
        parts = [house(self.rng), pd, pt, name, st, sd]
        text = " ".join(p for p in parts if p)
        return text.upper() if caps else text

    def us_unit(self):
        return self.pick([f"Apt {self.rng.randint(1, 40)}{self.pick(['', 'A', 'B', 'C', 'D'])}", f"Apt. {self.rng.randint(1, 999)}",
                          f"Suite {self.rng.randint(100, 2400)}", f"Ste {self.rng.randint(100, 999)}", f"#{self.rng.randint(1, 999)}",
                          f"Unit {self.rng.randint(1, 60)}{self.pick(['', 'B'])}", f"Floor {self.rng.randint(2, 40)}",
                          f"{self.rng.randint(2, 30)}th Floor", f"Bldg {self.pick('ABCDEFG')}", f"Apartment {self.rng.randint(1, 30)}",
                          f"Room {self.rng.randint(100, 900)}", f"PMB {self.rng.randint(100, 999)}", f"Lot {self.rng.randint(1, 200)}"])

    def make_us(self):
        loc = self.place("US")
        caps = self.chance(0.08)
        region = loc.region_code if self.chance(0.85) else loc.region
        zip_ = loc.postal + ("-" + digits(self.rng, 4) if self.chance(0.12) else "")
        gap = self.pick([" ", " ", " ", "  "])
        city_line = [loc.place, region + gap + zip_] if self.chance(0.85) else [f"{loc.place} {region}{gap}{zip_}"]
        if caps:
            city_line = [p.upper() for p in city_line]
        r = self.rng.random()
        if r < 0.08:
            box = self.pick(["PO Box", "P.O. Box", "Post Office Box", "P O Box", "PO BOX"]) + " " + str(self.rng.randint(1, 99999))
            return Address([[box], city_line], "US", "box")
        street = self.us_street(caps)
        lines = [[street]]
        if self.chance(0.3):
            unit = self.us_unit()
            unit = unit.upper() if caps else unit
            r2 = self.rng.random()
            if r2 < 0.42:
                lines[0].append(unit)
            elif r2 < 0.6:
                lines[0][0] = street + " " + unit
            else:
                lines.append([unit])
        if self.chance(0.1):
            building = self.pick(self.last) + " " + self.pick(["Building", "Plaza", "Tower", "Center", "Hall", "Commons", "House", "Centre", "Pavilion"])
            lines.insert(0, [self.pick([f"Room {self.rng.randint(1, 9)}.{self.rng.randint(1, 40):02d}", f"Room {self.rng.randint(100, 999)}", f"Floor {self.rng.randint(2, 30)}", f"Level {self.rng.randint(2, 30)}", f"Suite {self.rng.randint(100, 999)}", ""]), building])
        if r < 0.17:
            return Address(lines, "US", "street")
        if r < 0.22:
            return Address([city_line], "US", "locality")
        return Address(lines + [city_line], "US")

    def ca_postal(self, loc):
        return loc.postal + self.pick([" ", " ", ""]) + digits(self.rng, 1) + letters(self.rng, 1, "ABCEGHJKLMNPRSTVWXYZ") + digits(self.rng, 1)

    def make_ca(self):
        loc = self.place("CA")
        prov = loc.region_code if self.chance(0.8) else CA_PROVINCES.get(loc.region_code, loc.region)
        postal = self.ca_postal(loc)
        gap = self.pick([" ", " ", "  "])
        city_line = self.pick([[loc.place, prov + gap + postal], [f"{loc.place} {prov}{gap}{postal}"], [loc.place, prov, postal]])
        r = self.rng.random()
        if r < 0.07:
            box = self.pick(["PO Box", "P.O. Box", "C.P.", "CP"]) + " " + str(self.rng.randint(1, 9999))
            return Address([[box + (f" Stn {self.pick(['Main', 'A', 'Central'])}" if self.chance(0.3) else "")], city_line], "CA", "box")
        if loc.region_code == "QC" and self.chance(0.6):
            link = self.pick(FR_LINK)
            sep = "" if not link or link.endswith("-") or link.endswith("'") else " "
            street = f"{house(self.rng)}, {self.pick(['rue', 'boulevard', 'avenue', 'chemin', 'rang'])} {link}{sep}{self.stem(FR_WORDS)}".replace("  ", " ")
        else:
            _, _, name, st, sd = self.pick(self.us_streets)
            st = US_EXPAND.get(st, st) if self.chance(0.5) else st
            street = " ".join(p for p in [house(self.rng), name, st, sd] if p)
        lines = [[street]]
        if self.chance(0.08):
            lines.insert(0, [f"Room {self.rng.randint(1, 9)}.{self.rng.randint(1, 40):02d}", f"{self.pick(self.last)} {self.pick(['Building', 'Hall', 'Centre', 'Tower'])}"])
        if self.chance(0.3):
            unit = self.pick([f"Unit {self.rng.randint(1, 900)}", f"Suite {self.rng.randint(100, 2400)}", f"Apt {self.rng.randint(1, 1200)}", f"bureau {self.rng.randint(100, 900)}"])
            if self.chance(0.3):
                lines[0][0] = f"{self.rng.randint(1, 2500)}-{street}"
            elif self.chance(0.5):
                lines[0].append(unit)
            else:
                lines.insert(0, [unit])
        if r < 0.15:
            return Address(lines, "CA", "street")
        if r < 0.19:
            return Address([city_line], "CA", "locality")
        return Address(lines + [city_line], "CA")

    # -- Britain and Ireland, Oceania
    def gb_postal(self, loc):
        return loc.postal + self.pick([" ", " ", " ", ""]) + digits(self.rng, 1) + letters(self.rng, 2, "ABDEFGHJLNPQRSTUWXYZ")

    def gb_street(self):
        if self.chance(0.07):
            return self.pick(["High Street", "The Green", "The Avenue", "The Crescent", "The Square", "Church Street", "Station Road", "Main Street"])
        return f"{self.stem(GB_WORDS)} {self.pick(GB_TYPES)}"

    def make_gb(self):
        loc = self.place("GB")
        postal = self.gb_postal(loc)
        town = loc.place.upper() if self.chance(0.25) else loc.place
        lines = []
        r = self.rng.random()
        if self.chance(0.2):
            lines.append([self.pick([f"Flat {self.rng.randint(1, 40)}{self.pick(['', 'A', 'B'])}", f"Apartment {self.rng.randint(1, 120)}",
                                     f"Flat {self.pick('ABCDEF')}", f"Unit {self.rng.randint(1, 30)}", f"Suite {self.rng.randint(1, 20)}",
                                     f"{self.pick(['Ground', 'First', 'Second', 'Third', 'Top'])} Floor", f"Room {self.rng.randint(1, 400)}"])])
        if self.chance(0.15):
            building = f"{self.stem(GB_WORDS)} {self.pick(GB_BUILDINGS)}" if self.chance(0.7) else self.pick(["The Old Rectory", "The Old Forge", "The Coach House", "The Granary"])
            if lines and self.chance(0.6):
                lines[-1].append(building)
            else:
                lines.append([building])
        street = self.gb_street()
        if not (lines and self.chance(0.15)):
            street = f"{house(self.rng, high=400) if self.chance(0.95) else str(self.rng.randint(1, 99)) + self.pick('ab')} {street}"
            if self.chance(0.06):
                street = f"{self.rng.randint(1, 60)}-{self.rng.randint(61, 120)} {self.gb_street()}"
        lines.append([street])
        if self.chance(0.3):
            lines.append([self.pick(self.loc["GB"]).place])
        county = loc.county if loc.county and self.chance(0.2) else None
        style = self.rng.random()
        if style < 0.45:
            locality = [[town + self.pick([" ", " ", "  "]) + postal]]
        elif style < 0.8:
            locality = [[town], [postal]]
        else:
            locality = [[town], [county or loc.region], [postal]] if county or self.chance(0.3) else [[town, postal]]
        if county and style < 0.8:
            locality.insert(1, [county])
        if r < 0.06:
            box = self.pick(["PO Box", "P.O. Box"]) + " " + str(self.rng.randint(1, 9999))
            return Address([[box]] + locality, "GB", "box")
        if r < 0.16:
            return Address(lines, "GB", "street")
        return Address(lines + locality, "GB")

    def make_ie(self):
        loc = self.place("IE")
        eircode = loc.postal + " " + letters(self.rng, 1, "ACDEFHKNPRTVWXY") + digits(self.rng, 2) + letters(self.rng, 1, "ACDEFHKNPRTVWXY")
        street = f"{house(self.rng, high=300)} {self.stem(GB_WORDS)} {self.pick(['Street', 'Road', 'Avenue', 'Park', 'Lane', 'Terrace', 'Drive', 'Grove', 'Court', 'Lawn', 'Heights', 'Close'])}"
        lines = []
        if self.chance(0.2):
            lines.append([f"Apartment {self.rng.randint(1, 200)}", f"{self.stem(GB_WORDS)} {self.pick(['House', 'Court', 'Hall', 'Wharf'])}"])
        lines.append([street])
        if self.chance(0.4):
            lines.append([self.pick(self.loc["IE"]).place])
        county = self.pick(["Co. ", "County ", "Co "]) + self.pick(["Cork", "Kerry", "Galway", "Mayo", "Clare", "Wicklow", "Kildare", "Meath", "Donegal", "Sligo", "Tipperary", "Limerick", "Wexford"])
        town = loc.place
        locality = self.pick([[[town], [county], [eircode]], [[town, county, eircode]], [[town + " " + eircode]], [[f"Dublin {self.rng.randint(1, 24)}"], [eircode]]])
        if self.chance(0.12):
            return Address(lines, "IE", "street")
        return Address(lines + locality, "IE")

    def make_au(self):
        loc = self.place("AU")
        full, short = self.pick(AU_TYPES)
        stype = full if self.chance(0.5) else short
        street = f"{house(self.rng, high=999)} {self.stem(GB_WORDS)} {stype}"
        r = self.rng.random()
        lines = [[street]]
        if self.chance(0.3):
            unit = self.pick([f"Unit {self.rng.randint(1, 40)}", f"Level {self.rng.randint(1, 40)}", f"Suite {self.rng.randint(1, 12)}.{self.rng.randint(1, 30):02d}",
                              f"Shop {self.rng.randint(1, 40)}", f"Apartment {self.rng.randint(1, 900)}"])
            if self.chance(0.35):
                lines[0][0] = f"{self.rng.randint(1, 40)}/{street}"
            elif self.chance(0.5):
                lines[0].insert(0, unit)
            else:
                lines.insert(0, [unit])
        suburb = loc.place.upper() if self.chance(0.45) else loc.place
        state = loc.region_code if self.chance(0.85) else loc.region
        gap = self.pick([" ", " ", "  "])
        locality = self.pick([[f"{suburb} {state}{gap}{loc.postal}"], [suburb, f"{state} {loc.postal}"], [suburb, state, loc.postal]])
        if r < 0.07:
            box = self.pick(["PO Box", "GPO Box", "Locked Bag", "PO BOX"]) + " " + str(self.rng.randint(1, 9999))
            return Address([[box], locality], "AU", "box")
        if r < 0.16:
            return Address(lines, "AU", "street")
        return Address(lines + [locality], "AU")

    def make_nz(self):
        loc = self.place("NZ")
        street = f"{house(self.rng, high=999)}{self.pick(['', '', '', 'A', 'B'])} {self.stem(GB_WORDS)} {self.pick(NZ_TYPES)}"
        lines = [[street]]
        if self.chance(0.2):
            lines[0][0] = f"{self.rng.randint(1, 30)}/{street}"
        elif self.chance(0.2):
            unit = self.pick([f"Level {self.rng.randint(1, 30)}", f"Unit {self.rng.randint(1, 40)}", f"Flat {self.rng.randint(1, 12)}", f"Suite {self.rng.randint(1, 20)}"])
            if self.chance(0.6):
                lines[0].insert(0, unit)
            else:
                lines.insert(0, [unit])
        suburb = self.pick(self.loc["NZ"]).place
        city = loc.place
        locality = self.pick([[[suburb], [f"{city} {loc.postal}"]], [[suburb, f"{city} {loc.postal}"]], [[f"{city} {loc.postal}"]]])
        if self.chance(0.06):
            return Address([[f"{self.pick(['PO Box', 'Private Bag'])} {self.rng.randint(1, 99999)}"]] + locality, "NZ", "box")
        if self.chance(0.1):
            return Address(lines, "NZ", "street")
        return Address(lines + locality, "NZ")

    # -- Continental Europe
    def de_street(self, swiss=False):
        stem = self.stem(DE_WORDS)
        t = self.pick(DE_TYPES)
        if swiss and t == "straße":
            t = "strasse"
        if self.chance(0.12):
            name = f"{self.pick(['Am', 'An der', 'Im', 'Auf dem', 'Zum', 'In der'])} {stem}{self.pick(['', 'feld', 'berg', 'hof', 'garten', 'wald'])}"
        elif self.chance(0.15):
            name = f"{stem}er {t.capitalize()}" if t in ("straße", "strasse", "weg", "allee") else stem + t
        else:
            name = stem + t
        num = f"{self.rng.randint(1, 250)}{self.pick(['', '', '', '', 'a', 'b', ' a', '-12'])}"
        return f"{name} {num}"

    def make_de(self, country="DE"):
        loc = self.place(country)
        street = self.de_street(country == "CH")
        lines = []
        if self.chance(0.1):
            lines.append([self.pick([f"{self.rng.randint(1, 5)}. OG", "Hinterhaus", f"Wohnung {self.rng.randint(1, 30)}", f"Top {self.rng.randint(1, 30)}", "Gebäude B"])])
        lines.append([street])
        prefix = self.pick(["", "", "", "", "D-", "A-", "CH-"]) if country != "DE" or self.chance(0.1) else ""
        if prefix and prefix[0] != {"DE": "D", "AT": "A", "CH": "C"}[country]:
            prefix = ""
        city = loc.place
        if country == "AT" and self.chance(0.3):
            city = "Wien"
        locality = [f"{prefix}{loc.postal} {city.upper() if self.chance(0.1) else city}"]
        if self.chance(0.06):
            return Address([[f"Postfach {self.rng.randint(10, 99)} {self.rng.randint(10, 99)} {self.rng.randint(10, 99)}"], locality], country, "box")
        if self.chance(0.12):
            return Address(lines, country, "street")
        return Address(lines + [locality], country)

    def make_at(self):
        return self.make_de("AT")

    def make_ch(self):
        return self.make_de("CH")

    def make_fr(self):
        loc = self.place("FR")
        link = self.pick(FR_LINK)
        stem = self.stem(FR_WORDS)
        sep = "" if link.endswith("-") or link.endswith("'") else " "
        t = self.pick(FR_TYPES)
        t = t.capitalize() if self.chance(0.3) else t
        street = f"{self.rng.randint(1, 250)}{self.pick(['', '', '', '', ' bis', ' ter', 'B'])}{self.pick([' ', ', '])}{t} {link}{sep}{stem}".replace("  ", " ")
        lines = []
        if self.chance(0.15):
            lines.append([self.pick([f"Bâtiment {self.pick('ABCDE')}", f"Résidence Les {self.pick(['Pins', 'Tilleuls', 'Acacias', 'Lilas', 'Chênes'])}", f"Appt {self.rng.randint(1, 120)}",
                                     f"Escalier {self.rng.randint(1, 4)}", f"{self.rng.randint(1, 9)}e étage", "Lieu-dit Les Granges"])])
        lines.append([street.upper() if self.chance(0.08) else street])
        city = loc.place.upper() if self.chance(0.5) else loc.place
        locality = [f"{loc.postal} {city}" + (" CEDEX" if self.chance(0.04) else "")]
        if self.chance(0.06):
            return Address([[f"{self.pick(['BP', 'B.P.', 'CS'])} {self.rng.randint(1, 99999)}"], locality], "FR", "box")
        if self.chance(0.12):
            return Address(lines, "FR", "street")
        return Address(lines + [locality], "FR")

    def make_nl(self):
        loc = self.place("NL")
        street = f"{self.stem(NL_WORDS)}{self.pick(NL_TYPES)} {self.rng.randint(1, 450)}{self.pick(['', '', '', 'A', '-2', ' bis', '-hs', ' III'])}"
        postal = loc.postal + self.pick([" ", " ", ""]) + letters(self.rng, 2, "ABCDEGHJKLMNPRSTVWXZ")
        city = loc.place.upper() if self.chance(0.3) else loc.place
        locality = [f"{postal}{self.pick(['  ', ' '])}{city}"]
        if self.chance(0.06):
            return Address([[f"Postbus {self.rng.randint(1, 99999)}"], locality], "NL", "box")
        if self.chance(0.1):
            return Address([[street]], "NL", "street")
        return Address([[street], locality], "NL")

    def make_be(self):
        loc = self.place("BE")
        if self.chance(0.5):
            street = f"{self.stem(NL_WORDS)}{self.pick(NL_TYPES)} {self.rng.randint(1, 300)}{self.pick(['', '', '/2', ' bus 3', 'A'])}"
        else:
            street = f"{self.pick(['Rue', 'Avenue', 'Boulevard', 'Chaussée', 'Place'])} {self.pick(FR_LINK)} {self.stem(FR_WORDS)} {self.rng.randint(1, 300)}".replace("  ", " ").replace("' ", "'").replace("- ", "-")
        locality = [f"{self.pick(['', '', 'B-'])}{loc.postal} {loc.place}"]
        return Address([[street], locality], "BE") if self.chance(0.9) else Address([[street]], "BE", "street")

    def make_es(self):
        loc = self.place("ES")
        t = self.pick(ES_TYPES)
        link = self.pick(["", "", "de ", "del ", "de la ", "de los "])
        number = self.pick([f", {self.rng.randint(1, 200)}", f" {self.rng.randint(1, 200)}", f", nº {self.rng.randint(1, 200)}", f" {self.rng.randint(1, 200)}"])
        floor = self.pick(["", "", "", f", {self.rng.randint(1, 9)}º {self.pick('ABCD')}", f", {self.rng.randint(1, 9)}º izq.", f", {self.rng.randint(1, 9)}º dcha.", ", bajo", f" {self.rng.randint(1, 9)}-{self.pick('ABCD')}"])
        street = f"{t} {link}{self.stem(ES_WORDS)}{number}{floor}".replace("C/ ", "C/ " if self.chance(0.5) else "C/")
        city = loc.place
        locality = self.pick([[f"{loc.postal} {city}"], [f"{loc.postal} {city}", f"({loc.county})" if loc.county else loc.region], [f"{loc.postal} {city} ({loc.county or loc.region})"]])
        if self.chance(0.06):
            return Address([[f"Apartado {self.pick(['de Correos ', ''])}{self.rng.randint(1, 9999)}"], locality], "ES", "box")
        if self.chance(0.12):
            return Address([[street]], "ES", "street")
        return Address([[street], locality], "ES")

    def make_it(self):
        loc = self.place("IT")
        street = f"{self.pick(IT_TYPES)} {self.pick(['', '', 'della ', 'delle ', 'dei ', 'San '])}{self.stem(IT_WORDS)}{self.pick([' ', ', ', ' n. '])}{self.rng.randint(1, 250)}{self.pick(['', '', '', '/A', 'b', ' int. 4'])}"
        prov = loc.county or loc.region_code
        locality = self.pick([[f"{loc.postal} {loc.place} {prov}"], [f"{loc.postal} {loc.place} ({prov})"], [f"{loc.postal} {loc.place}"], [f"{loc.postal} - {loc.place} ({prov})"]])
        if self.chance(0.06):
            return Address([[f"Casella Postale {self.rng.randint(1, 999)}"], locality], "IT", "box")
        if self.chance(0.12):
            return Address([[street]], "IT", "street")
        return Address([[street], locality], "IT")

    def make_pt(self):
        loc = self.place("PT")
        street = f"{self.pick(PT_TYPES)} {self.pick(['', '', 'da ', 'do ', 'das ', 'dos ', 'de '])}{self.stem(PT_WORDS)}{self.pick([', ', ' ', ', nº '])}{self.rng.randint(1, 300)}{self.pick(['', '', '', f', {self.rng.randint(1, 9)}º Esq.', f', {self.rng.randint(1, 9)}º Dto.', ' r/c', f', {self.rng.randint(1, 9)}º andar'])}"
        locality = [f"{loc.postal} {loc.place}"]
        if self.chance(0.1):
            return Address([[street]], "PT", "street")
        return Address([[street], locality], "PT")

    def make_nordic(self, country, types, words):
        loc = self.place(country)
        t = self.pick(types)
        stem = self.stem(words)
        name = (stem + t) if not t.startswith(" ") else (stem + t)
        street = f"{name} {self.rng.randint(1, 120)}{self.pick(['', '', '', ' A', 'B', ', 2. tv.', ' lgh 1102', ' 3 tr'])}"
        prefix = self.pick(["", "", "", f"{country}-"])
        locality = [f"{prefix}{loc.postal} {loc.place.upper() if self.chance(0.2) else loc.place}"]
        if self.chance(0.06):
            return Address([[f"{self.pick(['Box', 'Postboks', 'PL'])} {self.rng.randint(1, 9999)}"], locality], country, "box")
        if self.chance(0.1):
            return Address([[street]], country, "street")
        return Address([[street], locality], country)

    def make_se(self):
        return self.make_nordic("SE", SE_TYPES, SE_WORDS)

    def make_dk(self):
        return self.make_nordic("DK", DK_TYPES, SE_WORDS)

    def make_no(self):
        return self.make_nordic("NO", NO_TYPES, SE_WORDS)

    def make_fi(self):
        return self.make_nordic("FI", FI_TYPES, FI_WORDS)

    def make_pl(self):
        loc = self.place("PL")
        t = self.pick(PL_TYPES)
        street = f"{t + ' ' if t else ''}{self.pick(PL_WORDS)} {self.rng.randint(1, 200)}{self.pick(['', '', f'/{self.rng.randint(1, 80)}', f' m. {self.rng.randint(1, 80)}', 'A'])}"
        locality = [f"{loc.postal} {loc.place}"]
        if self.chance(0.1):
            return Address([[street]], "PL", "street")
        return Address([[street], locality], "PL")

    def make_cz(self):
        loc = self.place("CZ")
        street = f"{self.pick(CZ_WORDS)} {self.rng.randint(1, 3000)}{self.pick(['', f'/{self.rng.randint(1, 80)}'])}"
        locality = [f"{loc.postal} {loc.place}"]
        if self.chance(0.1):
            return Address([[street]], "CZ", "street")
        return Address([[street], locality], "CZ")

    # -- elsewhere
    def make_in(self):
        loc = self.place("IN")
        lines = []
        if self.chance(0.6):
            lines.append([self.pick([f"Flat {self.rng.randint(1, 30)}{self.rng.randint(1, 9):02d}", f"House No. {self.rng.randint(1, 900)}", f"#{self.rng.randint(1, 999)}",
                                     f"Plot {self.rng.randint(1, 400)}", f"No. {self.rng.randint(1, 200)}/{self.rng.randint(1, 20)}"]),
                          f"{self.stem(GB_WORDS)} {self.pick(IN_BUILDINGS)}" if self.chance(0.6) else ""])
        lines.append([self.pick(IN_WORDS) if self.chance(0.6) else f"{self.rng.randint(1, 20)}th Cross, {self.rng.randint(1, 9)}th Main"])
        if self.chance(0.5):
            lines.append([self.pick(self.loc["IN"]).place])
        city = loc.county or loc.place
        locality = self.pick([[f"{city}, {loc.region} {loc.postal}"], [f"{city} - {loc.postal}", loc.region], [city, f"{loc.region} - {loc.postal}"]])
        return Address(lines + [locality], "IN")

    def make_sg(self):
        postal = digits(self.rng, 6)
        if self.chance(0.5):
            street = f"{self.pick(['Blk', 'Block', ''])} {self.rng.randint(1, 999)} {self.pick(SG_WORDS)} {self.pick(['Ave', 'Avenue', 'Street', 'St', 'Road', 'Drive'])} {self.rng.randint(1, 12)}".strip()
            unit = f"#{self.rng.randint(1, 30):02d}-{self.rng.randint(1, 400):02d}"
            lines = [[street + " " + unit]] if self.chance(0.5) else [[street], [unit]]
        else:
            lines = [[f"{self.rng.randint(1, 500)} {self.pick(SG_ROADS)}"], [f"#{self.rng.randint(1, 50):02d}-{self.rng.randint(1, 20):02d}", f"{self.stem(GB_WORDS)} {self.pick(SG_BUILDINGS)}"]]
        return Address(lines + [[f"Singapore {postal}"]], "SG")

    def make_za(self):
        loc = self.place("ZA")
        street = f"{house(self.rng, high=999)} {self.stem(GB_WORDS)} {self.pick(ZA_TYPES)}"
        suburb = self.pick(self.loc["ZA"]).place
        locality = self.pick([[[suburb], [loc.place], [loc.postal]], [[suburb, loc.place, loc.postal]], [[loc.place + " " + loc.postal]]])
        if self.chance(0.08):
            return Address([[f"PO Box {self.rng.randint(1, 9999)}"]] + locality, "ZA", "box")
        return Address([[street]] + locality, "ZA")

    def make_mx(self):
        loc = self.place("MX")
        street = f"{self.pick(['Calle', 'Av.', 'Avenida', 'Calz.', 'Blvd.', ''])} {self.pick(MX_WORDS)} {self.rng.randint(1, 3000)}{self.pick(['', '', f' Int. {self.rng.randint(1, 40)}', f' Depto. {self.rng.randint(1, 900)}', ' Piso 3'])}".strip()
        col = f"Col. {self.pick(MX_COLONIAS)}"
        state = loc.region
        locality = self.pick([[f"C.P. {loc.postal}", f"{loc.county or loc.place}", state], [f"{loc.postal} {loc.county or loc.place}", state], [f"{loc.county or loc.place}, {state} {loc.postal}"]])
        return Address([[street, col], locality] if self.chance(0.6) else [[street], [col], locality], "MX")

    def make_br(self):
        loc = self.place("BR")
        street = f"{self.pick(['Rua', 'Av.', 'Avenida', 'Alameda', 'Travessa', 'R.'])} {self.stem(PT_WORDS)}, {self.rng.randint(1, 3000)}{self.pick(['', '', f' - Apto {self.rng.randint(1, 300)}', f', apto. {self.rng.randint(1, 300)}', f' - Sala {self.rng.randint(1, 30)}', ' - Bloco B'])}"
        bairro = self.pick(["Bela Vista", "Centro", "Jardim Paulista", "Pinheiros", "Copacabana", "Botafogo", "Savassi", "Moinhos de Vento", "Boa Viagem", "Vila Madalena"])
        uf = self.pick(BR_UF)
        cep = loc.postal if "-" in loc.postal else digits(self.rng, 5) + "-" + digits(self.rng, 3)
        lines = self.pick([[[street], [bairro], [f"{loc.place} - {uf}", cep]], [[street, bairro], [f"{loc.place} - {uf}", f"CEP {cep}"]], [[street + " - " + bairro], [f"{cep} {loc.place}/{uf}"]]])
        return Address(lines, "BR")

    def make_jp(self):
        postal = digits(self.rng, 3) + "-" + digits(self.rng, 4)
        area = self.pick(self.loc["JP"]).place.split()[0]
        chome = f"{self.rng.randint(1, 9)}-{self.rng.randint(1, 30)}-{self.rng.randint(1, 30)}"
        city = self.pick(JP_CITIES)
        lines = self.pick([[[f"{chome} {area}", self.pick(JP_WARDS)], [f"{city} {postal}"]], [[f"{chome} {area}", self.pick(JP_WARDS), f"{city} {postal}"]],
                           [[f"{self.stem(GB_WORDS)} Building {self.rng.randint(2, 12)}F"], [f"{chome} {area}", self.pick(JP_WARDS)], [f"{city}-shi" if self.chance(0.3) else city, postal]]])
        return Address(lines, "JP")
