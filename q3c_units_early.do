* q3c_units_early.do — Q3 final model: army composition and game length
*
* For each race, using the player's army at minute `um' (default 6:00, i.e.
* measured before any "early" game has ended):
*   (1) P(game ends before 12:00)       which unit choices lead to short games
*   (2) P(win | game ended early)        which units win short games
*   (3) P(win | game lasted 12+ min)     which units win long games
* plus a joint test that unit effects on winning are equal in early and long
* games (pooled model with unit x early interactions).
*
* Sample matches Q1: players of the race studied; mirror games enter once.
* Needs prepped.dta (run 01_prep.do first) and units.csv with minute `um'.
* Output: results/q3_units_early.docx (one table per race) and .xlsx

clear all
include "~/sc2data/00_settings.do"     // Windows: "E:/sc2data/00_settings.do"
local um 6                             // minute army composition is measured (< 12)

use "$prepped", clear

* =============================================================================
* Army composition at minute `um' (same unit cleaning as 01_prep.do)
* =============================================================================
preserve
    import delimited "$base/sc2_data/units.csv", clear varnames(1) stringcols(1 3 5)
    keep if minute == `um'
    replace unit = regexr(unit, "Burrowed$", "")
    replace unit = "SiegeTank" if unit == "SiegeTankSieged"
    replace unit = "Viking"    if inlist(unit, "VikingAssault", "VikingFighter")
    replace unit = "Liberator" if unit == "LiberatorAG"
    replace unit = "Hellbat"   if unit == "HellionTank"
    replace unit = "Thor"      if unit == "ThorAP"
    replace unit = "Lurker"    if unit == "LurkerMP"
    replace unit = "SwarmHost" if unit == "SwarmHostMP"
    drop if regexm(unit, "Cocoon|Egg|Changeling|Interceptor|Broodling|Locust|PhaseShift|DisruptorPhased|AutoTurret|PointDefenseDrone|MULE")
    collapse (sum) count, by(game_id slot unit)
    reshape wide count, i(game_id slot) j(unit) string
    rename count* u`um'_*
    tempfile ucomp
    save `ucomp'
restore
merge 1:1 game_id slot using `ucomp', nogen keep(master match)

forvalues R = 1/3 {
    foreach u of local units`R' {
        capture confirm variable u`um'_`u'
        if _rc gen u`um'_`u' = 0
        replace u`um'_`u' = 0 if missing(u`um'_`u')
        label var u`um'_`u' "`u'"
    }
}

* Game-state controls at minute `um'
gen abs_w = abs(workers_diff_m`um')        // size of worker gap (either side)
gen abs_a = abs(army_diff100_m`um')        // size of army gap, per 100 res.

* =============================================================================
* Models, by race
* =============================================================================
tempname H
tempfile tab
postfile `H' str8 race int seq str48 rowlab str28 c1 str28 c2 str28 c3 using `tab', replace

forvalues R = 1/3 {
    local rname : word `R' of Terran Protoss Zerg
    local s "race_n == `R' & (mirror == 0 | pick == 1) & duration_s >= `um'*60 & !missing(early)"
    local wctrl "workers_diff_m`um' army_diff100_m`um'"

    * Units common enough in BOTH early and long games, so all three columns
    * and the interaction test use the same units
    local X ""
    foreach u of local units`R' {
        quietly count if `s' & early == 1 & u`um'_`u' > 0
        local ne = r(N)
        quietly count if `s' & early == 0 & u`um'_`u' > 0
        if `ne' >= `minobs' & r(N) >= `minobs' local X `X' u`um'_`u'
    }
    if "`X'" == "" {
        display as error "`rname': no unit common enough at minute `um' — skipped"
        continue
    }
    local allrows `X' abs_w abs_a `wctrl'

    * --- (1) early ending, (2) win | early, (3) win | 12+ min ---
    forvalues k = 1/3 {
        if `k' == 1 {
            local dv   early
            local cond ""
            local ctrl "abs_w abs_a"
        }
        if `k' == 2 {
            local dv   win
            local cond "& early == 1"
            local ctrl "`wctrl'"
        }
        if `k' == 3 {
            local dv   win
            local cond "& early == 0"
            local ctrl "`wctrl'"
        }
        capture noisily {
            logit `dv' `X' `ctrl' i.opp_n i.patch_id if `s' `cond', vce(cluster player_id)
            local N`k' = e(N)
            margins, dydx(`X' `ctrl')
            matrix T = r(table)
        }
        local ok = (_rc == 0)
        if !`ok' local N`k' "."

        foreach v of local allrows {
            local cell_`k'_`v' ""
            if `ok' {
                local c = colnumb(T, "`v'")
                if !missing(`c') {
                    if !missing(T[2,`c']) {
                        local p  = T[4,`c']
                        local st = cond(`p' < .01, "***", cond(`p' < .05, "**", cond(`p' < .10, "*", "")))
                        local b  : display %5.2f 100*T[1,`c']
                        local se : display %4.2f 100*T[2,`c']
                        local cell_`k'_`v' = trim("`b'") + "`st' (" + trim("`se'") + ")"
                    }
                    else local cell_`k'_`v' "—"
                }
            }
        }
    }

    * --- Test: are unit effects on winning the same in early and long games? ---
    local pdiff "."
    capture noisily {
        logit win i.early##c.(`X') `wctrl' i.opp_n i.patch_id if `s', vce(cluster player_id)
        local tl ""
        foreach v of local X {
            local tl `tl' 1.early#c.`v'
        }
        test `tl'
        local pdiff = r(p)
    }
    if "`pdiff'" != "." {
        local pdiff = cond(`pdiff' < .001, "<0.001", string(`pdiff', "%5.3f"))
    }

    * --- Write this race's rows ---
    local q = 0
    post `H' ("`rname'") (`q') ("") ("P(ends <12 min)") ("Win | early") ("Win | 12+ min")
    foreach v of local X {
        local ++q
        local lab : variable label `v'
        post `H' ("`rname'") (`q') ("`lab'") ("`cell_1_`v''") ("`cell_2_`v''") ("`cell_3_`v''")
    }
    local ++q
    post `H' ("`rname'") (`q') ("Worker gap at `um':00 (size)") ("`cell_1_abs_w'") ("") ("")
    local ++q
    post `H' ("`rname'") (`q') ("Army gap at `um':00 (size, per 100)") ("`cell_1_abs_a'") ("") ("")
    local ++q
    post `H' ("`rname'") (`q') ("Worker lead at `um':00") ("") ///
        ("`cell_2_workers_diff_m`um''") ("`cell_3_workers_diff_m`um''")
    local ++q
    post `H' ("`rname'") (`q') ("Army lead at `um':00 (per 100)") ("") ///
        ("`cell_2_army_diff100_m`um''") ("`cell_3_army_diff100_m`um''")
    local ++q
    post `H' ("`rname'") (`q') ("Opponent-race and patch FE") ("Yes") ("Yes") ("Yes")
    local ++q
    post `H' ("`rname'") (`q') ("Player-games") ("`N1'") ("`N2'") ("`N3'")
    local ++q
    post `H' ("`rname'") (`q') ("Unit effects equal, early vs. 12+ (p)") ("") ("") ("`pdiff'")
}
postclose `H'

* =============================================================================
* Output: Excel (one sheet per race) and Word (one table per race)
* =============================================================================
use `tab', clear
sort race seq
forvalues R = 1/3 {
    local rname : word `R' of Terran Protoss Zerg
    quietly count if race == "`rname'"
    if r(N) == 0 continue
    export excel rowlab c1 c2 c3 using "$out/q3_units_early.xlsx" ///
        if race == "`rname'", sheet("`rname'", replace)
}
display as result "Saved $out/q3_units_early.xlsx"

capture noisily {
    putdocx clear
    putdocx begin, font("Calibri", 10)
    forvalues R = 1/3 {
        local rname : word `R' of Terran Protoss Zerg
        preserve
            keep if race == "`rname'"
            sort seq
            if _N > 0 {
                local last = _N
                putdocx paragraph
                putdocx text ("`rname': army composition at `um':00, game length and winning"), bold
                putdocx table t`R' = data(rowlab c1 c2 c3), layout(autofitcontents) border(all, nil)
                putdocx table t`R'(1,.), bold border(top) border(bottom)
                putdocx table t`R'(`=`last'-2',.), border(top)
                putdocx table t`R'(`last',.), border(bottom)
                forvalues j = 2/4 {
                    putdocx table t`R'(.,`j'), halign(right)
                }
                putdocx paragraph
                putdocx text ("Notes: Average marginal effects in percentage points, standard errors clustered by player in parentheses. Unit rows: effect of one additional unit alive at `um':00. Column 1: probability the game ends before 12:00, controlling for the size of the worker and army gaps. Columns 2-3: probability of winning in games that ended before 12:00 and in games lasting 12 minutes or longer, controlling for the player's worker and army leads. Units included if at least `minobs' players had one in both early and long games. Last row: joint test that unit effects on winning are equal in early and long games. * p<0.10, ** p<0.05, *** p<0.01."), italic
            }
        restore
    }
    putdocx save "$out/q3_units_early.docx", replace
}
if _rc display as error _n "Word tables not written (error " _rc "). Use q3_units_early.xlsx instead."
else   display as result "Saved $out/q3_units_early.docx"
