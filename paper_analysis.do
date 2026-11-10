* =============================================================================
* paper_analysis.do — all results for "On Observing StarCraft 2 Tournament Data"
*
*   Q1  Unit choice by race, holding opponent race and game time fixed,
*       with the mirror matchup (TvT / PvP / ZvZ) as the counterfactual baseline
*   Q2  Bases and win probability, holding game time fixed
*   Q3  What predicts a game ending early (< 12 min), and who wins those games
*
* Needs: games.csv and units.csv from the latest sc2_extract.py
* One-time setup:  ssc install estout, replace
* Output: tables (.rtf for Word, .csv for Excel) in  sc2data/results/
* =============================================================================

version 16
clear all
set more off
set seed 20261020                      // makes the random player pick reproducible

global base "~/sc2data"                // Windows: "E:/sc2data"
global out  "$base/results"
capture mkdir "$out"

local q1min  8 12                      // snapshot minutes for Q1
local m      8                         // snapshot minute for Q2 main models
local minobs 20                        // a unit enters a model only if >= this
                                       // many players had at least one

* =============================================================================
* 0. DATA PREPARATION
* =============================================================================
import delimited "$base/sc2_data/games.csv", clear varnames(1) stringcols(_all)
destring slot win duration_s first_gas_s first_production_s natural_s third_s ///
    expand_first *_m4 *_m6 *_m8 *_m10 *_m12, replace force
duplicates drop game_id slot, force

keep if expansion == "LotV"
bysort game_id: gen byte n_in_game = _N
keep if n_in_game == 2                 // both players present
drop n_in_game

gen patch = regexs(0) if regexm(release, "^[0-9]+\.[0-9]+")
encode patch,   gen(patch_id)
encode matchup, gen(matchup_id)
encode player,  gen(player_id)

* Race codes: 1 = Terran, 2 = Protoss, 3 = Zerg
label define racelbl 1 "Terran" 2 "Protoss" 3 "Zerg"
gen byte race_n = cond(race == "Terran", 1, cond(race == "Protoss", 2, cond(race == "Zerg", 3, .)))
gen byte opp_n  = cond(opp_race == "Terran", 1, cond(opp_race == "Protoss", 2, cond(opp_race == "Zerg", 3, .)))
label values race_n opp_n racelbl
drop if missing(race_n, opp_n)
gen byte mirror = race_n == opp_n

* One randomly chosen player per game. Used wherever each game should count once:
* mirror games in Q1, and all games in Q2 and Q3.
sort game_id slot
by game_id: gen double r = runiform() if _n == 1
by game_id: replace r = r[1]
gen byte pick = (slot == 1 & r < .5) | (slot == 2 & r >= .5)
drop r

* Rescaled controls and labels
foreach t in 4 6 8 10 12 {
    gen army_diff100_m`t' = army_value_diff_m`t' / 100
    gen opp_bases_m`t'    = bases_m`t' - bases_diff_m`t'
    label var workers_diff_m`t'   "Worker lead"
    label var army_diff100_m`t'   "Army value lead (per 100 res.)"
    label var bases_diff_m`t'     "Base lead"
    label var opp_bases_m`t'      "Opponent's bases"
}

* Q3 variables (game-level: same value for both players of a game)
gen byte early = duration_s < 720 if !missing(duration_s)
label var early "Game ended before 12:00"
bysort game_id: egen g_min_prod  = min(first_production_s)
bysort game_id: egen g_min_gas   = min(first_gas_s)
bysort game_id: egen g_both_exp  = min(expand_first)
gen g_min_prod10   = g_min_prod / 10
gen g_min_gas10    = g_min_gas  / 10
gen g_abs_workers4 = abs(workers_diff_m4)
gen g_abs_army4    = abs(army_diff100_m4)
gen own_prod10     = first_production_s / 10
label var g_min_prod10   "Earliest production building, either player (per 10 s)"
label var g_min_gas10    "Earliest gas, either player (per 10 s)"
label var g_both_exp     "Both players expanded before production"
label var g_abs_workers4 "Worker gap between players at 4:00"
label var g_abs_army4    "Army value gap at 4:00 (per 100 res.)"
label var expand_first   "Expanded before first production building"
label var own_prod10     "Own first production building (per 10 s)"

* Unordered matchup for game-level models (TvZ and ZvT are the same game type)
gen g_matchup = cond(race_n <= opp_n, ///
    substr(race, 1, 1) + "v" + substr(opp_race, 1, 1), ///
    substr(opp_race, 1, 1) + "v" + substr(race, 1, 1))
encode g_matchup, gen(g_matchup_id)

* ---- Army composition at each Q1 minute (from units.csv) --------------------
local units1 Marine Marauder Reaper Hellion Hellbat WidowMine SiegeTank Cyclone ///
             Thor Viking Medivac Liberator Banshee Raven Ghost Battlecruiser
local units2 Zealot Stalker Sentry Adept HighTemplar DarkTemplar Archon Immortal ///
             Colossus Disruptor Phoenix VoidRay Oracle Tempest Carrier
local units3 Zergling Baneling Roach Ravager Hydralisk Lurker Mutalisk Corruptor ///
             Infestor SwarmHost Ultralisk BroodLord Viper Queen

foreach t of local q1min {
    preserve
        import delimited "$base/sc2_data/units.csv", clear varnames(1) stringcols(1 3 5)
        keep if minute == `t'
        * Merge unit modes into one unit (sieged tank = tank, burrowed roach = roach ...)
        replace unit = regexr(unit, "Burrowed$", "")
        replace unit = "SiegeTank" if unit == "SiegeTankSieged"
        replace unit = "Viking"    if inlist(unit, "VikingAssault", "VikingFighter")
        replace unit = "Liberator" if unit == "LiberatorAG"
        replace unit = "Hellbat"   if unit == "HellionTank"
        replace unit = "Thor"      if unit == "ThorAP"
        replace unit = "Lurker"    if unit == "LurkerMP"
        replace unit = "SwarmHost" if unit == "SwarmHostMP"
        * Drop temporary/spawned units that aren't production choices
        drop if regexm(unit, "Cocoon|Egg|Changeling|Interceptor|Broodling|Locust|PhaseShift|DisruptorPhased|AutoTurret|PointDefenseDrone|MULE")
        collapse (sum) count, by(game_id slot unit)
        reshape wide count, i(game_id slot) j(unit) string
        rename count* u`t'_*
        tempfile u`t'
        save `u`t''
    restore
    merge 1:1 game_id slot using `u`t'', nogen keep(master match)

    forvalues R = 1/3 {
        foreach u of local units`R' {
            capture confirm variable u`t'_`u'
            if _rc gen u`t'_`u' = 0
            replace u`t'_`u' = 0 if missing(u`t'_`u')
            label var u`t'_`u' "`u'"
        }
    }
}

compress
tempfile prepped
save `prepped'

* ---- Table 1: summary statistics (one row per game) -------------------------
estpost summarize win duration_s early workers_m8 bases_m8 army_value_m8 ///
    avg_bank_minerals_m8 avg_bank_gas_m8 upgrades_m8 if pick
esttab using "$out/table1_summary.rtf", replace ///
    cells("mean(fmt(2)) sd(fmt(2)) min(fmt(0)) max(fmt(0)) count(fmt(0))") ///
    nomtitles nonumbers label title("Summary statistics (one player per game)")
tab g_matchup if pick                   // games by matchup, for the Data section


* =============================================================================
* Q1. UNIT CHOICE BY RACE, MIRROR MATCHUP AS BASELINE
*
* For each race and snapshot minute:
*   - one logit per opponent race (columns: vs Terran / vs Protoss / vs Zerg),
*     army composition + worker and army-value leads + patch FEs
*   - a pooled model with unit x opponent-race interactions (mirror = base);
*     the "differs from mirror" row tests whether that column's unit effects
*     are jointly different from the mirror-matchup effects.
* Mirror games enter once (randomly chosen player); other games contribute the
* one player of the race being studied.
* =============================================================================
foreach t of local q1min {
    forvalues R = 1/3 {
        local rname : label racelbl `R'
        local base_s "race_n == `R' & (mirror == 0 | pick == 1) & duration_s >= `t'*60"
        local ctrl   "workers_diff_m`t' army_diff100_m`t'"

        * --- separate model per opponent race ---
        local est ""
        local mt  ""
        forvalues O = 1/3 {
            local oname : label racelbl `O'
            local s "`base_s' & opp_n == `O'"
            local X ""
            foreach u of local units`R' {
                quietly count if `s' & u`t'_`u' > 0
                if r(N) >= `minobs' local X `X' u`t'_`u'
            }
            if "`X'" == "" continue

            capture noisily {
                logit win `X' `ctrl' i.patch_id if `s', vce(cluster player_id)
                margins, dydx(`X' `ctrl') post
                estimates store q1_`t'_`R'_`O'
            }
            if _rc continue
            local est `est' q1_`t'_`R'_`O'
            if `O' == `R' local mt `"`mt' "vs `oname' (mirror)""'
            else          local mt `"`mt' "vs `oname'""'
        }
        if "`est'" == "" continue

        * --- pooled interaction model: do unit effects differ from the mirror? ---
        local Xp ""
        foreach u of local units`R' {
            local ok 1
            forvalues O = 1/3 {
                quietly count if `base_s' & opp_n == `O' & u`t'_`u' > 0
                if r(N) < `minobs' local ok 0
            }
            if `ok' local Xp `Xp' u`t'_`u'
        }
        if "`Xp'" != "" {
            capture noisily logit win ib`R'.opp_n##c.(`Xp') `ctrl' i.patch_id ///
                if `base_s', vce(cluster player_id)
            if !_rc {
                estimates store pooled
                forvalues O = 1/3 {
                    if `O' == `R' continue
                    quietly estimates restore pooled
                    local tl ""
                    foreach v of local Xp {
                        local tl `tl' `O'.opp_n#c.`v'
                    }
                    quietly test `tl'
                    capture estadd scalar p_mirror = r(p) : q1_`t'_`R'_`O'
                }
            }
        }

        * --- table ---
        local opts transform(100*@ 100) b(1) se(1) star(* 0.10 ** 0.05 *** 0.01) ///
            label nobaselevels varwidth(32) mtitles(`mt') ///
            stats(N p_mirror, labels("Player-games" "Unit effects = mirror (p-value)") fmt(0 3)) ///
            title("Q1: `rname' army composition and win probability at minute `t'") ///
            addnotes("Average marginal effects on win probability (percentage points) of one additional unit." ///
                     "Logit with patch FEs; SEs clustered by player. Units included if >= `minobs' players built one." ///
                     "Last row: joint test that unit effects equal those in the mirror matchup (pooled interaction model).")
        esttab `est', `opts'
        esttab `est' using "$out/q1_`rname'_m`t'.rtf", `opts' replace
        esttab `est' using "$out/q1_`rname'_m`t'.csv", `opts' replace plain
    }
}


* =============================================================================
* Q2. BASES AND WIN PROBABILITY (one player per game)
* =============================================================================
use `prepped', clear
keep if pick

* 1. Raw base lead
logit win bases_diff_m`m' i.matchup_id i.patch_id, vce(cluster player_id)
margins, dydx(bases_diff_m`m') post
estimates store q2_1

* 2. Holding economy and army fixed
logit win bases_diff_m`m' workers_diff_m`m' army_diff100_m`m' ///
    i.matchup_id i.patch_id, vce(cluster player_id)
margins, dydx(bases_diff_m`m' workers_diff_m`m' army_diff100_m`m') post
estimates store q2_2

* 3. Own base count as categories (is the 3rd base worth more than the 4th?)
logit win i.bases_m`m' opp_bases_m`m' i.matchup_id i.patch_id, vce(cluster player_id)
margins, dydx(bases_m`m') post
estimates store q2_3

local opts transform(100*@ 100) b(1) se(1) star(* 0.10 ** 0.05 *** 0.01) ///
    label nobaselevels varwidth(36) stats(N, labels("Games") fmt(0)) ///
    addnotes("Average marginal effects on win probability, percentage points." ///
             "Logit with matchup and patch FEs; SEs clustered by player; one randomly chosen player per game.")
esttab q2_1 q2_2 q2_3, `opts' mtitles("Raw" "+ economy" "Base count") ///
    title("Q2: Bases and win probability at minute `m'")
esttab q2_1 q2_2 q2_3 using "$out/q2_bases.rtf", `opts' replace ///
    mtitles("Raw" "+ economy" "Base count") title("Q2: Bases and win probability at minute `m'")
esttab q2_1 q2_2 q2_3 using "$out/q2_bases.csv", `opts' replace plain ///
    mtitles("Raw" "+ economy" "Base count")

* 4. Base lead at each minute (game time held fixed by snapshot)
foreach t in 4 6 8 10 12 {
    quietly logit win bases_diff_m`t' workers_diff_m`t' army_diff100_m`t' ///
        i.matchup_id i.patch_id, vce(cluster player_id)
    quietly margins, dydx(bases_diff_m`t') post
    estimates store q2_t`t'
}
local opts2 transform(100*@ 100) b(1) se(1) star(* 0.10 ** 0.05 *** 0.01) ///
    rename(bases_diff_m4 lead bases_diff_m6 lead bases_diff_m8 lead ///
           bases_diff_m10 lead bases_diff_m12 lead) coeflabels(lead "One-base lead") ///
    mtitles("4 min" "6 min" "8 min" "10 min" "12 min") stats(N, labels("Games") fmt(0)) ///
    addnotes("Average marginal effect of a one-base lead, controlling for worker and army leads.")
esttab q2_t*, `opts2' title("Q2: Effect of a one-base lead by game time")
esttab q2_t* using "$out/q2_bases_by_minute.rtf", `opts2' replace ///
    title("Q2: Effect of a one-base lead by game time")


* =============================================================================
* Q3. EARLY GAME ENDINGS (< 12 MINUTES)
*   A: which games end early (game-level, unordered matchup FEs)
*   B/C: who wins early games vs. longer games (player perspective)
* =============================================================================
use `prepped', clear
keep if pick

tab early g_matchup, col                  // share of early games by matchup

* A. Probability the game ends before 12:00
logit early g_min_prod10 g_min_gas10 g_both_exp g_abs_workers4 g_abs_army4 ///
    i.g_matchup_id i.patch_id, vce(cluster player_id)
margins, dydx(g_min_prod10 g_min_gas10 g_both_exp g_abs_workers4 g_abs_army4) post
estimates store q3_a

* B. Who wins early games / C. same model in games lasting 12+ minutes
local wx expand_first own_prod10 workers_diff_m4 army_diff100_m4
logit win `wx' i.matchup_id i.patch_id if early == 1, vce(cluster player_id)
margins, dydx(`wx') post
estimates store q3_b
logit win `wx' i.matchup_id i.patch_id if early == 0, vce(cluster player_id)
margins, dydx(`wx') post
estimates store q3_c

local opts transform(100*@ 100) b(1) se(1) star(* 0.10 ** 0.05 *** 0.01) ///
    label nobaselevels varwidth(48) stats(N, labels("Games") fmt(0)) ///
    mtitles("P(ends < 12 min)" "Win | early" "Win | 12+ min") ///
    addnotes("Average marginal effects, percentage points. Col. 1: game-level outcome with" ///
             "unordered matchup FEs; cols. 2-3: win outcome for a randomly chosen player," ///
             "matchup FEs. All models include patch FEs; SEs clustered by player.")
esttab q3_a q3_b q3_c, `opts' title("Q3: What predicts early game endings, and who wins them")
esttab q3_a q3_b q3_c using "$out/q3_early.rtf", `opts' replace ///
    title("Q3: What predicts early game endings, and who wins them")
esttab q3_a q3_b q3_c using "$out/q3_early.csv", `opts' replace plain

display as result _n "All tables saved to $out"
