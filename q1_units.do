* q1_units.do — Q1: unit choice by race, mirror matchup as baseline.
* Needs prepped.dta (run 01_prep.do first). Can be re-run on its own.

clear all
include "~/sc2data/00_settings.do"     // Windows: "E:/sc2data/00_settings.do"
use "$prepped", clear

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


