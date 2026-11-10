* q2_bases.do — Q2: bases and win probability.
* Needs prepped.dta (run 01_prep.do first). Can be re-run on its own.

clear all
include "~/sc2data/00_settings.do"     // Windows: "E:/sc2data/00_settings.do"
use "$prepped", clear
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
* 5. BY RACE, MIRROR AS BASELINE
*    For each race: effect of a one-base lead against each opponent race at
*    each minute (controlling for worker and army leads, patch FEs), plus a
*    joint test that the effect equals the mirror-matchup effect.
*    Sample matches Q1: race r players; mirror games enter once.
*    Output: q2_bases_by_race.docx (Word) and q2_bases_by_race.csv
* =============================================================================
use "$prepped", clear

tempname H
tempfile byrace
postfile `H' int seq str8 race str24 minute str24 c1 str24 c2 str24 c3 ///
    str24 ptest str12 nobs using `byrace', replace

local seq 0
forvalues R = 1/3 {
    local rname : label racelbl `R'
    local h1 = cond(`R' == 1, "vs Terran (mirror)", "vs Terran")
    local h2 = cond(`R' == 2, "vs Protoss (mirror)", "vs Protoss")
    local h3 = cond(`R' == 3, "vs Zerg (mirror)", "vs Zerg")
    local ++seq
    post `H' (`seq') ("`rname'") ("Minute") ("`h1'") ("`h2'") ("`h3'") ///
        ("Differs from mirror (p)") ("Player-games")

    foreach t in 4 6 8 10 12 {
        local s    "race_n == `R' & (mirror == 0 | pick == 1)"
        local ctrl "workers_diff_m`t' army_diff100_m`t'"

        * --- separate model per opponent: AME of a one-base lead ---
        forvalues O = 1/3 {
            local b`O'  "."
            local se`O' ""
            capture {
                logit win bases_diff_m`t' `ctrl' i.patch_id if `s' & opp_n == `O', ///
                    vce(cluster player_id)
                margins, dydx(bases_diff_m`t')
                matrix T = r(table)
            }
            if !_rc {
                local p  = T[4,1]
                local st = cond(`p' < .01, "***", cond(`p' < .05, "**", cond(`p' < .10, "*", "")))
                local b`O'  : display %4.1f 100*T[1,1]
                local b`O'  = trim("`b`O''") + "`st'"
                local se`O' : display %4.1f 100*T[2,1]
                local se`O' = "(" + trim("`se`O''") + ")"
            }
        }

        * --- pooled model: does the base effect differ from the mirror? ---
        local pt "."
        local N  "."
        capture {
            logit win ib`R'.opp_n##c.bases_diff_m`t' `ctrl' i.patch_id if `s', ///
                vce(cluster player_id)
            local N = e(N)
            testparm i.opp_n#c.bases_diff_m`t'
        }
        if !_rc {
            local pt : display %5.3f r(p)
            if r(p) < .001 local pt "<0.001"
        }

        local ++seq
        post `H' (`seq') ("`rname'") ("`t' min") ("`b1'") ("`b2'") ("`b3'") ("`pt'") ("`N'")
        local ++seq
        post `H' (`seq') ("`rname'") ("") ("`se1'") ("`se2'") ("`se3'") ("") ("")
    }
}
postclose `H'

* --- Write the tables -------------------------------------------------------
use `byrace', clear
sort seq
label var minute "Minute"

* (1) Excel: one sheet per race. Cells are stored as text, so "(1.2)" stays
*     a standard error instead of turning into -1.2.
forvalues R = 1/3 {
    local rname : word `R' of Terran Protoss Zerg
    export excel minute c1 c2 c3 ptest nobs using "$out/q2_bases_by_race.xlsx" ///
        if race == "`rname'", sheet("`rname'", replace)
}
display as result "Saved $out/q2_bases_by_race.xlsx"

* (2) Word: one table per race (needs Stata 15 or newer)
capture noisily {
    putdocx clear
    putdocx begin
    forvalues R = 1/3 {
        local rname : word `R' of Terran Protoss Zerg
        putdocx paragraph
        putdocx text ("Q2: Effect of a one-base lead on win probability, `rname'"), bold
        putdocx table t`R' = data(minute c1 c2 c3 ptest nobs) if race == "`rname'"
        putdocx paragraph
        putdocx text ("Average marginal effect of a one-base lead (percentage points); separate logits by opponent race with worker and army-value leads and patch FEs. SEs clustered by player in parentheses. * p<0.10, ** p<0.05, *** p<0.01. 'Differs from mirror' is a joint test from a pooled interaction model."), italic
    }
    putdocx save "$out/q2_bases_by_race.docx", replace
}
if _rc {
    display as error _n "Word table not written (error " _rc "). Use q2_bases_by_race.xlsx instead."
}
else display as result "Saved $out/q2_bases_by_race.docx"
