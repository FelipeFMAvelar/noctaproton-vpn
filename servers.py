#!/usr/bin/env python3
"""Fetch Proton VPN servers from the client's own cache, no hardcoding.

The CLI has no server-list command (`protonvpn servers` just prints a URL),
but the GTK/CLI client caches the full logical server list (~18k entries) at
~/.cache/Proton/VPN/serverlist.json, refreshed whenever it connects or when
`protonvpn countries/cities list` runs. Reading it here is far cheaper than a
1s CLI round-trip and gives us load and tier per server, which
`protonvpn connect <NAME>` then accepts directly.

Country names come from Proton's own
`proton.vpn.session.servers.country_codes` module, never from a hardcoded
table in this plugin.

Usage:
  servers.py --countries              all countries, with server/city counts
  servers.py --cities                  every city worldwide, with lat/long
  servers.py --cities <CODE> [limit]   one country's cities, best-first
  servers.py <CODE> [limit]            same as above (legacy shorthand)
  servers.py --servers <CODE> [CITY] [limit]
                                       every server in a country or city,
                                       fastest-first
  servers.py --locate <SERVER_NAME>    one server's city and coordinates
  servers.py --stats                   totals: countries, cities, servers
Prints compact JSON, or [] / {} when the cache is missing.
"""
import json
import os
import sys

# Proton's feature bitmask, from proton.vpn.session.servers.enums.
SECURE_CORE = 1
TOR = 2
P2P = 4
STREAMING = 8

CACHE = os.path.expanduser("~/.cache/Proton/VPN/serverlist.json")


def country_name(code):
    """Country name from Proton's own table, never hardcoded here."""
    try:
        from proton.vpn.session.servers.country_codes import (
            get_country_name_by_code,
        )

        return get_country_name_by_code(code) or code
    except Exception:
        return code


def labels(features):
    out = []
    if features & P2P:
        out.append("P2P")
    if features & TOR:
        out.append("Tor")
    if features & STREAMING:
        out.append("Streaming")
    return out


def read_cache():
    try:
        with open(CACHE, "r") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def status_known(data):
    """Whether Status carries any information in this cache.

    Proton fills Status in from a *separate* "loads" refresh
    (`Status = 1 if server_load.enabled else 0` in its own types.py). Until
    that call has succeeded, or when it fails, every server in the file reads
    Status 0. That means "we don't know yet", not "all 18,000 servers are
    down", and taking it literally empties the map and every city list.

    So Status is honoured only when at least one server is marked up.
    """
    for s in data.get("LogicalServers") or []:
        if s.get("Status") == 1:
            return True
    return False


def usable(s, check_status=True):
    """Connectable, and not Secure Core (those are reached via --securecore)."""
    if check_status and s.get("Status") != 1:
        return False
    return not ((s.get("Features") or 0) & SECURE_CORE)


def all_countries(data):
    """Every country: server count, city count, average load, lowest tier."""
    check_status = status_known(data)
    by_code = {}
    for s in data.get("LogicalServers") or []:
        if not usable(s, check_status):
            continue
        code = (s.get("ExitCountry") or "").upper()
        if not code:
            continue
        city = (s.get("City") or "").strip()
        entry = by_code.get(code)
        if entry is None:
            entry = {
                "code": code,
                "cities_set": set(),
                "count": 0,
                "load_sum": 0,
                "load_n": 0,
                "tier": None,
                "score": None,
            }
            by_code[code] = entry
        entry["count"] += 1
        if city:
            entry["cities_set"].add(city)
        load = s.get("Load")
        if load is not None:
            try:
                entry["load_sum"] += int(load)
                entry["load_n"] += 1
            except (TypeError, ValueError):
                pass
        tier = s.get("Tier")
        if tier is not None and (entry["tier"] is None or tier < entry["tier"]):
            entry["tier"] = tier
        score = s.get("Score")
        if score is not None and (entry["score"] is None or score < entry["score"]):
            entry["score"] = score
    rows = []
    for code, e in by_code.items():
        rows.append({
            "code": code,
            "name": country_name(code),
            "count": e["count"],
            "cities": len(e["cities_set"]),
            "load": round(e["load_sum"] / e["load_n"]) if e["load_n"] else 50,
            "tier": e["tier"] if e["tier"] is not None else 2,
        })
    rows.sort(key=lambda r: r["name"])
    return rows


def all_cities(data):
    """Every city worldwide: one entry per (country, city) with its coordinates
    and best server. Feeds the panel's mini-map; ~200 rows for ~18k servers."""
    out = {}
    check_status = status_known(data)
    for s in data.get("LogicalServers") or []:
        if not usable(s, check_status):
            continue
        loc = s.get("Location") or {}
        lat, lon = loc.get("Lat"), loc.get("Long")
        if lat is None or lon is None:
            continue
        code = (s.get("ExitCountry") or "").upper()
        city = (s.get("City") or "").strip()
        if code == "" or city == "":
            continue
        score = s.get("Score")
        score = score if score is not None else 9e9
        key = (code, city)
        entry = out.get(key)
        if entry is None or score < entry["score"]:
            out[key] = {
                "code": code,
                "country": country_name(code),
                "city": city,
                "lat": round(float(lat), 3),
                "lon": round(float(lon), 3),
                "name": s.get("Name") or "",
                "load": s.get("Load"),
                "tier": s.get("Tier"),
                "score": score,
                "tags": labels(s.get("Features") or 0),
                "count": (entry["count"] + 1) if entry else 1,
            }
        else:
            entry["count"] += 1
    rows = sorted(out.values(), key=lambda r: (r["code"], r["city"]))
    for r in rows:
        del r["score"]
    return rows


def cities_in_country(data, code, limit=500):
    """One row per city in a country, fastest-first with best server."""
    code = code.strip().upper()
    cities = {}
    check_status = status_known(data)
    for s in data.get("LogicalServers") or []:
        if check_status and s.get("Status") != 1:
            continue
        if (s.get("ExitCountry") or "").upper() != code:
            continue
        features = s.get("Features") or 0
        if features & SECURE_CORE:
            continue
        city = (s.get("City") or "").strip() or "Other"
        loc = s.get("Location") or {}
        score = s.get("Score")
        score = score if score is not None else 9e9
        load = s.get("Load")
        load = load if load is not None else 999

        entry = cities.get(city)
        if entry is None:
            cities[city] = {
                "code": code,
                "country": country_name(code),
                "city": city,
                "name": s.get("Name") or "",
                "load": s.get("Load"),
                "tier": s.get("Tier"),
                "score": score,
                "tags": labels(features),
                "lat": loc.get("Lat"),
                "lon": loc.get("Long"),
                "count": 1,
            }
            continue

        entry["count"] += 1
        if (score, load) < (entry["score"],
                            entry["load"] if entry["load"] is not None else 999):
            entry.update({
                "name": s.get("Name") or "",
                "load": s.get("Load"),
                "tier": s.get("Tier"),
                "score": score,
                "tags": labels(features),
                "lat": loc.get("Lat"),
                "lon": loc.get("Long"),
            })

    rows = sorted(cities.values(), key=lambda r: r["score"])
    for r in rows:
        del r["score"]
    return rows[:limit]


def servers_in(data, code, city=None, limit=1000):
    """Every server in a country (or one city), fastest-first.

    This is what lets the panel show *all* servers instead of one row per
    city: a per-city query is typically <100 rows, small enough to push
    through Noctalia state on demand.
    """
    code = code.strip().upper()
    want_city = (city or "").strip().lower() if city else None
    rows = []
    check_status = status_known(data)
    for s in data.get("LogicalServers") or []:
        if check_status and s.get("Status") != 1:
            continue
        if (s.get("ExitCountry") or "").upper() != code:
            continue
        features = s.get("Features") or 0
        if features & SECURE_CORE:
            continue
        scity = (s.get("City") or "").strip() or "Other"
        if want_city and scity.lower() != want_city:
            continue
        score = s.get("Score")
        score = score if score is not None else 9e9
        load = s.get("Load")
        rows.append({
            "code": code,
            "country": country_name(code),
            "city": scity,
            "name": s.get("Name") or "",
            "load": s.get("Load"),
            "tier": s.get("Tier"),
            "score": score,
            "tags": labels(features),
        })
    rows.sort(key=lambda r: (r["score"],
                             r["load"] if r["load"] is not None else 999,
                             r["name"]))
    for r in rows:
        del r["score"]
    return rows[:limit]


def stats(data):
    check_status = status_known(data)
    n_servers = 0
    countries = set()
    cities = set()
    for s in data.get("LogicalServers") or []:
        if not usable(s, check_status):
            continue
        n_servers += 1
        code = (s.get("ExitCountry") or "").upper()
        city = (s.get("City") or "").strip()
        if code:
            countries.add(code)
        if code and city:
            cities.add((code, city))
    return {
        "countries": len(countries),
        "cities": len(cities),
        "servers": n_servers,
    }


def country_place(data, code):
    """Where a country is, for the map: the location of its first regular
    server. Secure Core entry countries (CH, IS, SE) each have one city."""
    for s in data.get("LogicalServers") or []:
        if (s.get("ExitCountry") or "").upper() != code:
            continue
        if (s.get("Features") or 0) & SECURE_CORE:
            continue
        loc = s.get("Location") or {}
        if loc.get("Lat") is None or loc.get("Long") is None:
            continue
        return {
            "code": code,
            "city": (s.get("City") or "").strip(),
            "lat": loc.get("Lat"),
            "lon": loc.get("Long"),
        }
    return None


def locate(data, name):
    """Where one server is. Used to light up the connected city on the map.
    A Secure Core server (CH-US#3: enters Switzerland, exits New York) also
    carries its entry hop so the map can draw the route."""
    want = name.strip().upper()
    for s in data.get("LogicalServers") or []:
        if (s.get("Name") or "").upper() != want:
            continue
        loc = s.get("Location") or {}
        features = s.get("Features") or 0
        place = {
            "name": s.get("Name") or "",
            "code": (s.get("ExitCountry") or "").upper(),
            "city": (s.get("City") or "").strip(),
            "lat": loc.get("Lat"),
            "lon": loc.get("Long"),
            # Feature bit 4 is P2P. Most servers permit it, so the panel only
            # makes a point of it when that's what you asked for.
            "p2p": bool(features & P2P),
        }
        entry_code = (s.get("EntryCountry") or "").upper()
        if (s.get("Features") or 0) & SECURE_CORE and entry_code and entry_code != place["code"]:
            entry = country_place(data, entry_code)
            if entry:
                place["entry"] = entry
        return place
    return {}


def main():
    if len(sys.argv) < 2:
        print("[]")
        return
    arg = sys.argv[1]
    data = read_cache()

    if arg == "--countries":
        print(json.dumps(all_countries(data) if data else [], separators=(",", ":")))
        return
    if arg == "--stats":
        print(json.dumps(stats(data) if data else {"countries": 0, "cities": 0, "servers": 0},
                         separators=(",", ":")))
        return
    if arg == "--cities":
        # --cities [CODE] [limit]: worldwide when bare, one country otherwise.
        if len(sys.argv) >= 3 and sys.argv[2] and not sys.argv[2].startswith("--"):
            code = sys.argv[2]
            limit = int(sys.argv[3]) if len(sys.argv) > 3 else 500
            rows = cities_in_country(data, code, limit) if data else []
            print(json.dumps(rows, separators=(",", ":")))
            return
        print(json.dumps(all_cities(data) if data else [], separators=(",", ":")))
        return
    if arg == "--servers":
        if len(sys.argv) < 3:
            print("[]")
            return
        code = sys.argv[2]
        rest = sys.argv[3:]
        city = None
        limit = 1000
        # Rest is [CITY] [limit], with limit optional. A trailing integer
        # is a limit; anything else is a city name (which may be numeric,
        # so only treat the *last* token as a limit when there are 2+).
        if len(rest) == 1:
            try:
                limit = int(rest[0])
            except ValueError:
                city = rest[0]
        elif len(rest) >= 2:
            try:
                limit = int(rest[-1])
                city = " ".join(rest[:-1]) or None
            except ValueError:
                city = " ".join(rest) or None
        rows = servers_in(data, code, city, limit) if data else []
        print(json.dumps(rows, separators=(",", ":")))
        return
    if arg == "--locate":
        name = sys.argv[2] if len(sys.argv) > 2 else ""
        print(json.dumps(locate(data, name) if (data and name) else {}, separators=(",", ":")))
        return
    if data is None:
        print("[]")
        return
    # Legacy shorthand: servers.py <COUNTRY_CODE> [limit]
    if arg.startswith("--"):
        print("[]")
        return
    code = arg.strip().upper()
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 500
    print(json.dumps(cities_in_country(data, code, limit), separators=(",", ":")))


if __name__ == "__main__":
    main()
