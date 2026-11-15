# Blueprint from Helmod (In Development)

**This is not a finished mod. It is a work-in-progress personal project, published for the author's own use and convenient access from different computers.**

Create blueprints from your own Helmod plans. Press **Ctrl+B** to open the generator. Production machines, recipes, modules, qualities and configured beacon effects follow the selected plan. The plan is not automatically expanded with missing recipes.

## Local combined test build 1.4.122

Adds logarithmic capacity splitting, source-aligned item/fluid export banks, multiple configured shared beacons with module-aware validation, transport quality selection, experimental separate feeds for mixed ingredient qualities, and external-supply/shortfall diagnostics. Placement affinities no longer count the same recipe demand once per input port. FMF direction and capacity fallbacks have expanded offline regression coverage; this is not a new general-purpose fluid router.

Identical layout options are now skipped before calculating placement. All distinct options retain their order, including beacon and fluid-clearance adjustments. Normal search still stops at the first valid layout; thorough search compares the remaining candidates. The existing geometry and connection checks remain enabled.

This build has only been checked offline in Lua. Factorio installation, real blueprint output, throughput, per-tick performance, and save/load acceptance still require testing. Updating the mod cancels an unfinished generation through the existing update handler; start a fresh calculation. Already created blueprints are not migrated.

## Layout and logistics

- Connected layouts route resources between production blocks and collect external inputs and final outputs on the selected sides.
- Independent layouts keep separate blocks in a vertical list. Bus mode is currently unavailable.
- Select researched belts, pipes, inserters and compatible loaders. Sufficient inserters are retained; selected bottleneck policies handle supported insufficient operations.
- Optional DisplayPlatesForked signs label external inputs. Optional container distribution uses compatible loaders; strict equal free-output division is not guaranteed.
- Quality-aware flows, checked beacon cells and experimental Fluid Must Flow adapters are supported with the limitations below.

## Version 1.4.101

Eligible assemblers can share a beacon in two rows. The generator tries the largest group allowed by the template, belt capacity and beacon coverage, then smaller groups when needed. The gear test with fast belts reached eight machines per ordinary or wide beacon and two per compact beacon.

## Version 1.4.100

Two eligible assemblers from the same Helmod recipe can share one beacon in compatible solid-item layouts. The generator uses the selected beacon prototype and quality to determine coverage. This includes both variants of the compact and wide Space Exploration beacons. It uses separate cells when coverage or routing requires them.

A two-assembler test in Factorio 2.1.24 used one beacon instead of two for all five tested beacon prototypes. The final layout occupied 52–81% less bounding area depending on the prototype. Output through the belts differed by at most two gears over one game minute.

## Generation and verification

Generation runs incrementally and reports progress in chat. The interval is configurable: 10, 20, 30, 60 or 120 game seconds. Use **/bfh-cancel** to cancel. Results are delivered to the cursor or inventory when possible. Save/load continuation is supported; changes to generator version or relevant settings can require a new calculation.

The controlled test supplies the plan's external inputs, including ready-made processed fuel, and provides electric energy. It does not test mining, fuel production or electricity generation. Connection checks do not replace a throughput test in a sandbox. Startup buffers can cause temporary output fluctuations.

## Limitations

This project can still produce unsupported layouts, errors and long calculations. Minimum area, arbitrary-plan throughput and smooth multiplayer performance are not guaranteed. All multiplayer participants need the same mod version. The full joining-client network scenario has not been verified in the current test run.

Shared coverage applies to compatible solid-item templates and up to 64 configured beacons per assembler, subject to coverage and search limits. Multiple beacons remain excluded when Space Exploration is active. Other layouts can require separate cells. Some complex fluid layouts are unsupported. Fluid Must Flow substitution covers suitable clear straight sections, not every pipe.

Mixed ingredient qualities now retain separate feed identities; this is experimental and requires in-game checks across templates. Transport quality is selected separately; production machines and beacons retain Helmod settings. Transfer sizing remains conservative at normal quality. Quality output rates use Helmod's expected proportions; short measurements may fluctuate.

Requires Factorio 2.1.7+ and Helmod 2.3.6+. Restart Factorio and regenerate blueprints after updating. Verify results in a sandbox.

All Rights Reserved — MikdadAgasiev.
