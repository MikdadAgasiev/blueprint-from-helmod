# Blueprint from Helmod (In Development)

**This is not a finished mod. It is a work-in-progress personal project, published for the author's own use and convenient access from different computers.**

Create blueprints from your own Helmod plans. Press **Ctrl+B** to open the generator. Machines, recipes, modules, machine qualities and configured beacon effects follow the selected plan. Missing production recipes are not added automatically.

## Layout and logistics

- Connected layouts place and route production blocks, collecting external inputs and final outputs on the selected sides. Choose an automatic, square, horizontal or vertical target shape.
- Independent layouts keep separate blocks in a vertical list. Bus mode is currently unavailable.
- Choose researched belts, pipes, inserters and compatible loaders, or let automatic mode select suitable transport. Sufficient inserters are retained; bottleneck policies reinforce supported insufficient operations.
- The Exclusions tab stores an entity blacklist for each player. Automatic selection skips these entities; conflicting explicit or Helmod choices must be corrected before generation.
- Transport quality has a separate selector. Production equipment keeps its Helmod quality. Transfer sizing uses conservative normal-quality estimates.
- Eligible solid-item machine groups can share configured beacons. Coverage follows the selected beacon prototype and quality; final checks also compare installed modules. Space Exploration configurations retain their overload restrictions.
- Final item and fluid export banks are aligned with their production sources. Distinct quality feeds retain separate routing identities.

## Optional integrations

- **DisplayPlatesForked:** resource signs at external inputs.
- **ChangeInserterDropLane:** output-lane balancing where the downstream route preserves both lanes.
- **Fluid Must Flow:** suitable clear straight pipe sections can use ducts and their intake/outlet adapters. Direction and capacity restrictions still apply.
- **Large containers and loaders:** compatible storage can distribute external resources through loader connections. A shared buffer does not guarantee strict equal splitting between unblocked outputs. Special-purpose containers are excluded.

## Generation and diagnostics

Generation runs incrementally. Chat progress intervals are configurable: 10, 20, 30, 60 or 120 game seconds. Use **/bfh-cancel** to cancel. Completed blueprints are delivered to the cursor or inventory; **/bfh-take** retrieves a waiting result when delivery is blocked.

The generator reports known internal production shortfalls separately from external supplies and unknown rates. A connection check is followed by checks for supported belt, fluid, transfer, beacon and power constraints. Connection checks do not replace a throughput test in a sandbox.

Save/load continuation is supported. Updating the generator cancels an unfinished calculation; generate a fresh blueprint after updating. Already created blueprints are not migrated.

## Limitations

Unsupported layouts, errors and long calculations remain possible. Minimum area, arbitrary-plan throughput and smooth multiplayer performance are not guaranteed. All multiplayer participants need the same mod version.

Shared beacons apply to compatible solid-item templates, subject to coverage and search limits. Other layouts can use separate cells. Multiple configured beacons are excluded when Space Exploration is active. Complex fluid layouts and some modded equipment can require manual adjustments. Mixed ingredient qualities remain experimental; quality output rates use Helmod's expected proportions and fluctuate over short measurements.

External resources, fuel and electricity must be supplied. Mining, fuel-production expansion and electricity generation are not added automatically.

Requires Factorio **2.1.7+** and Helmod **2.3.6+**. Restart Factorio and regenerate blueprints after updating. Verify the result in a sandbox before using it in a factory.

MIT License — Copyright (c) 2026 MikdadAgasiev. Contributions and reproducible bug reports are welcome on GitHub.
