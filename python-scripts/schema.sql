CREATE TABLE states (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    boundary TEXT,
    center_lat REAL,
    center_lon REAL
);

CREATE TABLE counties (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    boundary TEXT,
    center_lat REAL,
    center_lon REAL
);

CREATE TABLE congressional_districts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    boundary TEXT,
    center_lat REAL,
    center_lon REAL
);

CREATE TABLE precincts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    boundary TEXT, -- GeoJSON stored as string
    center_lat REAL,
    center_lon REAL,
    population INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE county_precincts (
    precinct_id INTEGER REFERENCES precincts(id) ON DELETE CASCADE,
    county_id INTEGER REFERENCES counties(id) ON DELETE CASCADE,
    PRIMARY KEY(precinct_id, county_id)
);

CREATE TABLE congressional_district_precincts (
    precinct_id INTEGER REFERENCES precincts(id) ON DELETE CASCADE,
    congressional_district_id INTEGER REFERENCES congressional_districts(id) ON DELETE CASCADE,
    PRIMARY KEY(precinct_id, congressional_district_id)
);

CREATE TABLE state_regions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    state_id INTEGER REFERENCES states(id) ON DELETE CASCADE,
    region_id INTEGER NOT NULL,
    region_type TEXT CHECK(region_type IN ('county', 'congressional_district'))
);

CREATE TABLE parties (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL
);

CREATE TABLE candidates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    party_id INTEGER REFERENCES parties(id) ON DELETE SET NULL,
    office TEXT
);

CREATE TABLE precinct_results (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    precinct_id INTEGER REFERENCES precincts(id) ON DELETE CASCADE,
    candidate_id INTEGER REFERENCES candidates(id) ON DELETE CASCADE,
    votes INTEGER NOT NULL DEFAULT 0,
    UNIQUE(precinct_id, candidate_id)
);
