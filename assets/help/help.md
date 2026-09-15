# GerrymanderX Help

GerrymanderX is a precinct-level election atlas for macOS. It lets you explore U.S. presidential results state by state and precinct by precinct, compare two elections on the same map, and draw your own groupings of precincts to see how the vote would add up under different boundaries.

## Your Account

GerrymanderX asks you to sign in before the map opens. Signing in with your Google account creates the account on first use — there is no separate registration step and no password to remember.

- Your name and profile picture, as Google supplies them, sit at the bottom of the side menu. Click them to confirm which account you are signed in as, and to sign out.
- The session is remembered on this Mac, so you sign in once; after that the app opens straight to the map. Signing in does need a working connection.
- **Settings → Account** repeats the same information and adds *Delete Account*, which removes your account permanently.
- The account only identifies you. It holds nothing about your work — no election databases, no custom layers, no settings — and nothing you do in the app is uploaded to it.

## Quick Start

1. Sign in with your Google account when the app opens.
2. Open the **Elections** tab and click the list icon (☰) in the toolbar to show the election list.
3. Switch **Source** to **Remote**, pick an election (for example *2024 National President*), and click **Download All** — or download only the states you care about, one at a time.
4. Switch **Source** back to **Local**, expand the election and click **National** or a state to load it on the map.
5. Hover over the map to highlight a region, click it to open the **Inspector** with the vote totals and breakdown.

## Getting Election Data

Election databases are not bundled with the app; they are downloaded on demand so you only store what you use.

- **Remote** view lists every election available on our server. Each election has a **National** database plus one database per state.
- **Download All** fetches every database of an election; the per-state **Download** button fetches just one. Progress is shown live and any download can be cancelled.
- Interrupted downloads resume from where they stopped the next time you open the Remote list.
- **Local** view shows what is on your Mac. Use the trash icon (or right-click → *Delete*) to remove a whole election or a single state database.
- Databases live in `~/Documents/GerrymanderX/Databases/`. Dropping a compatible `.db` file into that folder and pressing the refresh button also makes it appear in the Local list.

## The Map

- **Pan**: drag. **Zoom**: scroll wheel / two-finger scroll (centred on the pointer) or pinch. The refresh button in the toolbar re-fits the view.
- **Layers**: in a state view, toggle `county`, `congressionalDistrict` and `precinct` with the **Layers** chips in the toolbar. The National view shows states only.
- **Interactive layer**: hover and click always act on the finest visible layer; you can override this with the *Interactive Layer* dropdown at the top of the Inspector.
- **Outlines**: states are drawn with a thick white border, counties thin white, congressional districts amber, precincts hairline. Borders stay crisp at any zoom.

## Fill Modes

The **Fill** dropdown in the toolbar controls how regions are coloured:

| Mode | What it shows |
|---|---|
| `none` | Boundaries only |
| `winnerOpaque` | Solid colour of the winning party |
| `winnerOpacity` | Winner colour, fading from white at 50 % share to solid at 75 %+ |
| `singleCandidateOpacity` | Pick a candidate; darker means a larger share |
| `winnerDotDensity` | One dot per region, sized by the winner's vote count |
| `singlePartyComparison` | Change in one party's share versus another election |
| `2-partyComparison` | Movement of the Party A − Party B margin versus another election |

## Comparing Two Elections

Comparison modes appear once a state — not National — is selected and there is **another election of that state** to compare with. Any two elections of the same state can be compared, whatever their year or office: 2024 President against 2024 US Senate, or 2024 President against 2022 US Senate.

1. Choose `singlePartyComparison` or `2-partyComparison` as the fill mode.
2. Pick the other election in the two **vs** dropdowns — its year, then its type (President, US Senate, US House, Governor) — and the **Party** (or **Party A** / **Party B**) to compare. The type list of the year on the map leaves out the election already shown.
3. The map colours each region by the swing; the Inspector shows a swing headline and side-by-side party totals for both elections.

Parties are matched by name across elections. Counties and districts are matched by name; precincts are matched geometrically (by location), because precinct numbering and boundaries change between elections. Regions with no counterpart are noted in the Inspector. A banner above the map tells you if anything needed for the comparison is still missing or loading.

## The Inspector

Click a region (or the ⓘ button) to open the Inspector on the right. It shows the region's name and layer, **total votes**, and **Votes by Candidate** with party colour, vote count, share bar and the winner in bold. In comparison mode it shows the swing and both elections' totals instead.

## Custom Layers

A custom layer is your own set of **group cells** — named, coloured collections of precincts that behave like counties or districts on the map. Use them to sketch alternative districts, neighbourhoods, or any region you want totals for.

- In a state view, use the **Custom** dropdown in the toolbar to show a layer, **+** to create a new one, and **Edit** to open the editor.
- In the editor: rename the layer, add groups (**+**), pick a colour from the swatch, then click counties, districts or precincts on the editor map to add all their precincts to the selected group; click again to remove them. A precinct belongs to at most one group per layer.
- The group inspector shows the group's composition (whole counties, whole districts, remaining precincts), total votes and vote breakdown — updated live as you draw.
- Changes are saved as you make them; there is no Save button. Deleting a group asks for confirmation when it contains precincts.
- Custom layers are tied to a specific election and state database. Deleting that election deletes its custom layers too.
- **Custom layers stay on this Mac and have nothing to do with your account.** They are stored under `~/Documents/GerrymanderX/`, never uploaded and never synced. Signing in on another Mac will not bring them with you, and signing in here as somebody else shows the same layers — they belong to the machine, not to the account.

## Settings

- **Account**: the account you are signed in as, with *Sign out* and *Delete Account*.
- **Theme**: System, Light or Dark.
- **Feedback**: opens your mail client with our address pre-filled.
- **Privacy Policy** and **About** (app version).

## Data Sources

Precinct results and boundaries come from the Voting and Election Science Team (VEST) via the Redistricting Data Hub and from the MIT Election Data + Science Lab (MEDSL). State, county and congressional-district boundaries come from the U.S. Census Bureau cartographic boundary files. A small share of precincts have no published boundary and cannot be drawn.

## Privacy

Signing in tells us only what Google hands over: your name, email address and profile picture. There is no analytics and no tracking. Apart from sign-in, GerrymanderX's only network activity is downloading the election list and databases you request from our server. Everything you download or draw — databases, custom layers, settings — is stored in `~/Documents/GerrymanderX/` on your Mac and nothing is ever uploaded. See the Privacy Policy in Settings for details.

## Troubleshooting

- **Sign-in does not complete** — the authorization opens in your browser and must be finished there; if you closed it, click the sign-in button again. A failed sign-in also needs a working internet connection.
- **The Remote list is empty or shows an error** — check your internet connection and press *Retry*.
- **Comparison modes are missing from the Fill dropdown** — select a state (not National) and make sure that state has a second election to compare with: another downloaded year, or another office in the same year.
- **A region shows no votes** — some precincts have boundaries but no reported results, or vice versa; the source data is incomplete for a few areas.
- **The map is slow at precinct level for large states** — hide the Precinct layer while panning, or zoom into the area of interest.
- **I want to start over** — delete the elections from the Local list, or quit the app and remove `~/Documents/GerrymanderX/`.
