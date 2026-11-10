* q3_early.do — Q3: early game endings.
* Needs prepped.dta (run 01_prep.do first). Can be re-run on its own.

clear all
include "~/sc2data/00_settings.do"     // Windows: "E:/sc2data/00_settings.do"
use "$prepped", clear
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

