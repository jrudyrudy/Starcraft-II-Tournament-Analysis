* analysis_starter.do — first regressions on sc2_extract.py output
* ssc install reghdfe ; ssc install ftools   (for absorbed fixed effects)

* Set this to your sc2data folder (Mac example; Windows: "E:/sc2data")
global base "~/sc2data"

import delimited "$base/sc2_data/games.csv", clear varnames(1) stringcols(_all)
destring slot win duration_s natural_s first_* *_m4 *_m6 *_m8 *_m10 *_m12 expand_first, replace force

* merge m:1 map using "$base/map_features.dta", nogen keep(master match)
* Each player-game must be unique (re-run sc2_extract.py if this fails)
duplicates drop game_id slot, force
isid game_id slot

keep if expansion == "LotV" & race == "Terran" & opp_race == "Zerg"
gen patch = regexs(0) if regexm(release, "^[0-9]+\.[0-9]+")
encode patch, gen(patch_id)
encode map,   gen(map_id)
encode player, gen(player_id)

* 1. Build order: expand-first vs. production-first
logit win expand_first natural_s i.patch_id i.map_id, vce(cluster player_id)
margins, dydx(expand_first)

* 2. Economy vs. army at 6 minutes
logit win workers_diff_m6 army_value_diff_m6 i.patch_id i.map_id, vce(cluster player_id)

* Linear probability version with absorbed FEs (faster with many maps/patches)
reghdfe win expand_first workers_diff_m6 army_value_diff_m6, absorb(patch_id map_id) vce(cluster player_id)

* 3. Unit composition at 8 min: reshape units.csv wide, then merge
preserve
    import delimited "$base/sc2_data/units.csv", clear varnames(1)
    duplicates drop game_id slot minute unit, force
    keep if minute == 8
    drop minute player
    reshape wide count, i(game_id slot) j(unit) string
    foreach v of varlist count* {
        replace `v' = 0 if missing(`v')
    }
    tempfile comp8
    save `comp8'
restore
merge 1:1 game_id slot using `comp8', nogen keep(master match)

logit win countMarine countMarauder countWidowMine countMedivac ///
    workers_diff_m8 army_value_diff_m8 i.patch_id, vce(cluster player_id)
