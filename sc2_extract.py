"""
sc2_extract.py — turn a folder of StarCraft II replays into regression-ready CSVs.

Default layout (no arguments needed) — relative to wherever this script is saved:
    <script folder>/replays     put replays here: .SC2Replay files OR the Zenodo .zip packs
    <script folder>/sc2_data    CSVs are written here

Usage:
    Mac:      python3 ~/sc2data/sc2_extract.py
    Windows:  py -3 E:\sc2data\sc2_extract.py
    Options:  [folder] [--out out_dir] [--minutes 4 6 8 10 12] [--workers 4]

Any .zip in the replay folder (including zips inside zips) is extracted next to
itself first, then all .SC2Replay files are found recursively. Only 1v1 games kept.

Outputs:
  games.csv   one row per PLAYER per game (2 rows per game). Outcome = win (0/1).
              Key: game_id + slot (1 or 2). Don't key on player name: some packs
              give both players the same (anonymized/barcode) name.
              Game info, races, map, patch, opener timings, and economy/army
              snapshots at each minute mark, plus the same stats as diffs vs. opponent.
  units.csv   long format: game_id, slot, player, minute, unit, count  (army units alive
              at that minute). Reshape wide in R (pivot_wider) or Stata (reshape wide).
  builds.csv  long format: game_id, slot, player, order, building, time_s  (every structure
              started, in order — use it to hand-code or cluster openers).
  errors.csv  replays that failed to parse, with the reason.

All times are in real seconds (what the in-game clock shows in LotV).
"""

import argparse
import csv
import hashlib
import os
import sys
import zipfile
from collections import Counter
from multiprocessing import Pool

import sc2reader

# ---------------------------------------------------------------- config
BASE = os.path.dirname(os.path.abspath(__file__))  # the folder this script is saved in
DEFAULT_REPLAYS = os.path.join(BASE, "replays")
DEFAULT_OUT = os.path.join(BASE, "sc2_data")

SUPPLY = {"SupplyDepot", "SupplyDepotLowered", "Pylon"}
IGNORE_BUILDINGS = SUPPLY | {"CreepTumor", "CreepTumorBurrowed", "CreepTumorQueen"}
TOWNHALLS = {"CommandCenter", "Nexus", "Hatchery"}
GAS = {"Refinery", "Assimilator", "Extractor", "RefineryRich", "AssimilatorRich", "ExtractorRich"}
PRODUCTION = {"Barracks", "Gateway", "SpawningPool"}
# tech milestones: (column name, unit type names that count)
TECH = {
    "lair_s": {"Lair"},
    "hive_s": {"Hive"},
    "factory_s": {"Factory"},
    "starport_s": {"Starport"},
    "cyberneticscore_s": {"CyberneticsCore"},
    "roboticsfacility_s": {"RoboticsFacility"},
    "stargate_s": {"Stargate"},
    "twilightcouncil_s": {"TwilightCouncil"},
    "roachwarren_s": {"RoachWarren"},
    "banelingnest_s": {"BanelingNest"},
    "spire_s": {"Spire"},
}
# fields copied from PlayerStatsEvent at each snapshot
STAT_FIELDS = {
    "workers": "workers_active_count",
    "supply": "food_used",
    "mineral_rate": "minerals_collection_rate",
    "gas_rate": "vespene_collection_rate",
    "army_value": None,          # computed: minerals + gas in active forces
    "minerals_lost_army": "minerals_lost_army",
    "gas_lost_army": "vespene_lost_army",
    "minerals_killed_army": "minerals_killed_army",
    "gas_killed_army": "vespene_killed_army",
}


def fps(replay):
    """Frames per real second. LotV clock is real time; earlier expansions used game time."""
    return 22.4 if replay.expansion == "LotV" else 16.0


def type_at(unit, frame):
    """Unit type name at a given frame (handles morphs like Hatchery->Lair, Roach->Ravager)."""
    name = None
    for f in sorted(unit.type_history):
        if f <= frame:
            name = unit.type_history[f].name
        else:
            break
    return name or (unit.name if unit.name else None)


def first_time(units, names, rate, exclude_start=False):
    """Earliest frame (as seconds) a unit of one of `names` started or morphed into existence."""
    best = None
    for u in units:
        for f, t in u.type_history.items():
            if t.name in names:
                start = u.started_at if f == min(u.type_history) else f
                if start is None:
                    continue
                if exclude_start and start == 0:
                    continue
                if best is None or start < best:
                    best = start
    return round(best / rate, 1) if best is not None else ""


def nth_townhall_time(units, n, rate):
    """Start time of the n-th townhall (n=2 natural, n=3 third). Starting base counts as 1."""
    starts = sorted(u.started_at for u in units
                    if u.started_at is not None and u.type_history
                    and u.type_history[min(u.type_history)].name in TOWNHALLS)
    return round(starts[n - 1] / rate, 1) if len(starts) >= n else ""


def stats_at(stat_events, frame):
    """Latest PlayerStatsEvent at or before frame (they fire every ~10s)."""
    best = None
    for e in stat_events:
        if e.frame <= frame:
            best = e
        else:
            break
    return best


def snapshot(stat_events, frame):
    e = stats_at(stat_events, frame)
    out = {}
    for col, attr in STAT_FIELDS.items():
        if e is None:
            out[col] = ""
        elif col == "army_value":
            out[col] = (e.minerals_used_active_forces or 0) + (e.vespene_used_active_forces or 0)
        else:
            out[col] = getattr(e, attr, "")
    return out


BASE_TYPES = {"CommandCenter", "CommandCenterFlying", "OrbitalCommand", "OrbitalCommandFlying",
              "PlanetaryFortress", "Nexus", "Hatchery", "Lair", "Hive"}


def bases_alive(units, frame):
    """Townhalls finished and not destroyed at frame (includes the starting base)."""
    n = 0
    for u in units:
        if not u.type_history or u.type_history[min(u.type_history)].name not in BASE_TYPES:
            continue
        done = u.finished_at if u.finished_at is not None else u.started_at
        if done is None or done > frame:
            continue
        if u.died_at is not None and u.died_at <= frame:
            continue
        n += 1
    return n


def army_alive(units, frame):
    """Counter of army unit types alive (finished, not dead) at frame."""
    c = Counter()
    for u in units:
        if not getattr(u, "is_army", False):
            continue
        done = u.finished_at if u.finished_at is not None else u.started_at
        if done is None or done > frame:
            continue
        if u.died_at is not None and u.died_at <= frame:
            continue
        name = type_at(u, frame)
        if name:
            c[name] += 1
    return c


def process(path_and_minutes):
    path, minutes = path_and_minutes
    try:
        with open(path, "rb") as fh:
            game_id = hashlib.md5(fh.read()).hexdigest()[:12]
        r = sc2reader.load_replay(path, load_level=4)
    except Exception as ex:
        return {"error": (path, f"{type(ex).__name__}: {ex}")}

    try:
        humans = [p for p in r.players if p.is_human]
        if len(r.teams) != 2 or len(humans) != 2 or any(len(t.players) != 1 for t in r.teams):
            return {"skip": (path, "not 1v1")}
        if not r.tracker_events:
            return {"error": (path, "no tracker events (replay older than patch 2.0.8)")}

        rate = fps(r)
        p1, p2 = humans
        stats = {p.pid: [] for p in humans}
        upgrades = {p.pid: [] for p in humans}
        for e in r.tracker_events:
            kind = type(e).__name__
            if kind == "PlayerStatsEvent" and e.pid in stats:
                stats[e.pid].append(e)
            elif kind == "UpgradeCompleteEvent" and e.pid in upgrades and e.frame > 0:
                name = e.upgrade_type_name or ""
                if not name.startswith(("Spray", "Reward", "GameHeart")):
                    upgrades[e.pid].append((e.frame, name))
        for v in stats.values():
            v.sort(key=lambda e: e.frame)

        game = {
            "game_id": game_id,
            "file": os.path.basename(path),
            "folder": os.path.basename(os.path.dirname(path)),
            "date": r.date.strftime("%Y-%m-%d") if r.date else "",
            "map": r.map_name,
            "release": r.release_string,
            "build": r.build,
            "expansion": r.expansion,
            "duration_s": round(r.frames / rate, 1),
        }

        game_rows, unit_rows, build_rows = [], [], []
        snaps = {}
        for slot, me in enumerate(humans, 1):
            units = list(me.units)
            snaps[me.pid] = {m: snapshot(stats[me.pid], int(m * 60 * rate)) for m in minutes}
            for m in minutes:
                f = int(m * 60 * rate)
                snaps[me.pid][m]["bases"] = bases_alive(units, f)
                upto = [e for e in stats[me.pid] if e.frame <= f]
                snaps[me.pid][m]["avg_bank_minerals"] = (
                    round(sum(e.minerals_current for e in upto) / len(upto), 1) if upto else "")
                snaps[me.pid][m]["avg_bank_gas"] = (
                    round(sum(e.vespene_current for e in upto) / len(upto), 1) if upto else "")
                ups = [n for fr, n in upgrades[me.pid] if fr <= f]
                snaps[me.pid][m]["upgrades"] = len(ups)
                snaps[me.pid][m]["upgrades_wa"] = sum("Level" in n for n in ups)

            # ordered structure list
            blds = sorted(
                [u for u in units if getattr(u, "is_building", False) and u.started_at is not None
                 and u.started_at > 0 and u.name not in IGNORE_BUILDINGS],
                key=lambda u: u.started_at)
            for i, u in enumerate(blds, 1):
                build_rows.append({"game_id": game_id, "slot": slot, "player": me.name, "order": i,
                                   "building": type_at(u, u.started_at),
                                   "time_s": round(u.started_at / rate, 1)})

            first_prod = first_time(units, PRODUCTION, rate)
            natural = nth_townhall_time(units, 2, rate)
            row = dict(game)
            opp = p2 if me is p1 else p1
            row.update({
                "slot": slot,
                "player": me.name,
                "race": me.play_race,
                "opp": opp.name,
                "opp_race": opp.play_race,
                "matchup": f"{me.play_race[0]}v{opp.play_race[0]}",
                "win": 1 if me.result == "Win" else 0,
                "opener_seq": "-".join(type_at(u, u.started_at) for u in blds[:6]),
                "first_gas_s": first_time(units, GAS, rate),
                "first_production_s": first_prod,
                "natural_s": natural,
                "third_s": nth_townhall_time(units, 3, rate),
                "expand_first": int(natural != "" and (first_prod == "" or natural < first_prod)),
            })
            for col, names in TECH.items():
                row[col] = first_time(units, names, rate)

            for m in minutes:
                for k, v in snaps[me.pid][m].items():
                    row[f"{k}_m{m}"] = v
                for unit, n in sorted(army_alive(units, int(m * 60 * rate)).items()):
                    unit_rows.append({"game_id": game_id, "slot": slot, "player": me.name, "minute": m,
                                      "unit": unit, "count": n})
            game_rows.append(row)

        # opponent differences (me minus opponent) — the controls for game state
        for row, me, opp in ((game_rows[0], p1, p2), (game_rows[1], p2, p1)):
            for m in minutes:
                for k in ("workers", "army_value", "mineral_rate", "gas_rate", "supply", "bases",
                          "avg_bank_minerals", "avg_bank_gas", "upgrades", "upgrades_wa"):
                    a, b = snaps[me.pid][m][k], snaps[opp.pid][m][k]
                    row[f"{k}_diff_m{m}"] = round(a - b, 1) if a != "" and b != "" else ""
                    # mark minutes the game hadn't reached
                    if m * 60 > game["duration_s"]:
                        row[f"{k}_m{m}"] = ""
                        row[f"{k}_diff_m{m}"] = ""

        return {"games": game_rows, "units": unit_rows, "builds": build_rows}
    except Exception as ex:
        return {"error": (path, f"{type(ex).__name__}: {ex}")}


def write_csv(path, rows):
    if not rows:
        return
    cols = []
    for r in rows:  # union of keys, first-seen order
        for k in r:
            if k not in cols:
                cols.append(k)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)


def unzip_all(folder):
    """Extract every .zip under folder (repeats so zips inside zips get opened too)."""
    done = set()
    while True:
        zips = [os.path.join(d, f) for d, _, fs in os.walk(folder)
                for f in fs if f.lower().endswith(".zip")]
        new = [z for z in zips if z not in done]
        if not new:
            return
        for z in new:
            done.add(z)
            target = z[:-4]
            if os.path.isdir(target):
                continue
            print(f"Unzipping {os.path.basename(z)}...")
            try:
                with zipfile.ZipFile(z) as zf:
                    zf.extractall(target)
            except zipfile.BadZipFile:
                print(f"  skipped (not a valid zip): {z}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", nargs="?", default=DEFAULT_REPLAYS)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--minutes", type=int, nargs="+", default=[4, 6, 8, 10, 12])
    ap.add_argument("--workers", type=int, default=max(1, (os.cpu_count() or 2) - 1))
    a = ap.parse_args()

    if not os.path.isdir(a.folder):
        os.makedirs(a.folder, exist_ok=True)
        sys.exit(f"Created {a.folder} — put your replays or Zenodo .zip packs in it, then run again.")
    unzip_all(a.folder)

    paths = [os.path.join(d, f) for d, _, fs in os.walk(a.folder)
             for f in fs if f.lower().endswith(".sc2replay")]
    if not paths:
        sys.exit(f"No .SC2Replay files found under {a.folder}")
    print(f"Parsing {len(paths)} replays with {a.workers} workers...")

    games, units, builds, errors, seen = [], [], [], [], set()
    skipped = 0
    with Pool(a.workers) as pool:
        for i, res in enumerate(pool.imap_unordered(process, [(p, a.minutes) for p in paths]), 1):
            if "error" in res:
                errors.append({"file": res["error"][0], "reason": res["error"][1]})
            elif "skip" in res:
                skipped += 1
            else:
                gid = res["games"][0]["game_id"]
                if gid in seen:  # duplicate replay files
                    continue
                seen.add(gid)
                games += res["games"]; units += res["units"]; builds += res["builds"]
            if i % 100 == 0:
                print(f"  {i}/{len(paths)}")

    os.makedirs(a.out, exist_ok=True)
    write_csv(os.path.join(a.out, "games.csv"), games)
    write_csv(os.path.join(a.out, "units.csv"), units)
    write_csv(os.path.join(a.out, "builds.csv"), builds)
    write_csv(os.path.join(a.out, "errors.csv"), errors)
    print(f"Done: {len(seen)} games ({len(games)} player rows), {skipped} non-1v1 skipped, "
          f"{len(errors)} errors -> {a.out}/")


if __name__ == "__main__":
    main()
