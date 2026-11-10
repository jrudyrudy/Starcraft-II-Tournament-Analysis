* q3b_early_race.do — Q3 (descriptive): which races win games that end early?
* Needs prepped.dta (run 01_prep.do first). Can be re-run on its own.
*
* Mirror games (TvT, PvP, ZvZ) are excluded: their winner's race is fixed.
* Output: results/q3_race_early.xlsx (Panel A by race, Panel B by matchup)

clear all
include "~/sc2data/00_settings.do"     // Windows: "E:/sc2data/00_settings.do"
use "$prepped", clear

keep if mirror == 0 & !missing(early)
label define earlylbl 0 "12+ min" 1 "Early (<12 min)"
label values early earlylbl

* ---- Quick look ---------------------------------------------------------------
* Share of early games by matchup
tab g_matchup early if race_n < opp_n, row
* Win rate by race, early vs. longer games (each non-mirror game has exactly
* one player of a given race, so each game counts once per race)
tabstat win if early == 1, by(race) statistics(mean n) format(%5.3f)
tabstat win if early == 0, by(race) statistics(mean n) format(%5.3f)

* ---- Build the results table ------------------------------------------------
tempname H
tempfile res
postfile `H' str8 panel str24 group double(win_early n_early win_late n_late diff p) ///
    using `res', replace

* Panel A: by race (all non-mirror games involving that race)
foreach r in Terran Protoss Zerg {
    quietly prtest win if race == "`r'", by(early)
    * by(early): group 1 = 12+ min (early==0), group 2 = early (early==1)
    post `H' ("A") ("`r'") (r(P_2)) (r(N_2)) (r(P_1)) (r(N_1)) ///
        (r(P_2) - r(P_1)) (2*normal(-abs(r(z))))
}

* Panel B: by matchup, from the first-listed race's side (T in TvP/TvZ, P in PvZ)
foreach mu in TvP TvZ PvZ {
    local first = substr("`mu'", 1, 1)
    local fr = cond("`first'" == "T", "Terran", "Protoss")
    quietly prtest win if g_matchup == "`mu'" & race_n < opp_n, by(early)
    post `H' ("B") ("`fr' win rate in `mu'") (r(P_2)) (r(N_2)) (r(P_1)) (r(N_1)) ///
        (r(P_2) - r(P_1)) (2*normal(-abs(r(z))))
}
postclose `H'

use `res', clear
foreach v in win_early win_late diff {
    replace `v' = round(100 * `v', 0.1)          // percent
}
replace p = round(p, 0.001)
label var panel     "Panel"
label var group     "Group"
label var win_early "Win % in early games"
label var n_early   "Early games"
label var win_late  "Win % in 12+ min games"
label var n_late    "12+ min games"
label var diff      "Difference (pp)"
label var p         "p-value"
list, noobs sepby(panel) abbreviate(24)
export excel using "$out/q3_race_early.xlsx", firstrow(varlabels) replace
display as result "Saved $out/q3_race_early.xlsx"

* ---- Regression check: early-game advantage by matchup -------------------------
* One row per non-mirror game (first-listed race's side), patch FEs,
* SEs clustered by player. Margins give the first race's win probability in
* early vs. longer games, and the difference, for each matchup.
use "$prepped", clear
keep if mirror == 0 & race_n < opp_n & !missing(early)

logit win i.early##i.g_matchup_id i.patch_id, vce(cluster player_id)
margins early, over(g_matchup_id)               // predicted win rates
margins r.early, over(g_matchup_id)             // early minus 12+, with tests
