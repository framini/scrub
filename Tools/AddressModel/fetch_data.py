"""Downloads the address parts the generator reads, into raw/:

- GeoNames postal code files, one per country (CC BY 4.0, https://www.geonames.org),
  unzipped into raw/geonames. GeoNames updates them, so a later download may
  differ slightly from the one the shipped weights were trained on (2 October 2026).
- US Census Bureau TIGER/Line 2024 FEATNAMES files for the counties in
  tiger-counties.txt (two per state, public domain), into raw/tiger.

Development only: nothing here runs when Scrub is built or used.

    python fetch_data.py
"""
import io
import os
import urllib.request
import zipfile

from places import COUNTRIES

HERE = os.path.dirname(os.path.abspath(__file__))


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "scrub-tools/1.0"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def main():
    geonames = os.path.join(HERE, "raw", "geonames")
    os.makedirs(geonames, exist_ok=True)
    for country in COUNTRIES:
        archive = zipfile.ZipFile(io.BytesIO(fetch(f"https://download.geonames.org/export/zip/{country}.zip")))
        archive.extract(f"{country}.txt", geonames)
    tiger = os.path.join(HERE, "raw", "tiger")
    os.makedirs(tiger, exist_ok=True)
    for name in open(os.path.join(HERE, "tiger-counties.txt")).read().split():
        with open(os.path.join(tiger, name), "wb") as f:
            f.write(fetch(f"https://www2.census.gov/geo/tiger/TIGER2024/FEATNAMES/{name}"))


if __name__ == "__main__":
    main()
