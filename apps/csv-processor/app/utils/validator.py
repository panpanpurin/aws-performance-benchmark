import pandas as pd

# Check required columns
REQUIRED_COLUMNS = {
    "pokemon_id", "name", "type", "level", "attack", "defense",
    "hp", "speed", "special_attack", "special_defense"
}

# Check allowed types
ALLOWED_TYPES = {
    "Grass", "Fire", "Water", "Electric", "Fairy",
    "Ghost", "Rock", "Psychic", "Normal", "Dark", "Fighting", "Poison", "Ground"
}

# Check numeric columns
NUMERIC_COLUMNS = [
    "pokemon_id", "level", "attack", "defense",
    "hp", "speed", "special_attack", "special_defense"
]

def validate_csv(df: pd.DataFrame):
    # Check for required columns
    missing = REQUIRED_COLUMNS - set(df.columns)
    if missing:
        raise ValueError(f"Missing required columns: {missing}")

    # Check for null values
    if df.isnull().values.any():
        raise ValueError("Missing values detected in the CSV")

    # Check for duplicate IDs
    if df["pokemon_id"].duplicated().any():
        raise ValueError("Duplicate 'pokemon_id' values found")

    # Check data types
    for col in NUMERIC_COLUMNS:
        if not pd.api.types.is_numeric_dtype(df[col]):
            raise ValueError(f"Column '{col}' must contain numeric values")

    # Check level range
    if not df["level"].between(1, 100).all():
        raise ValueError("All Pokémon levels must be between 1 and 100")

    # Check valid Pokémon types
    if not df["type"].isin(ALLOWED_TYPES).all():
        invalid = df[~df["type"].isin(ALLOWED_TYPES)]["type"].unique()
        raise ValueError(f"Invalid Pokémon type(s) found: {invalid}")
