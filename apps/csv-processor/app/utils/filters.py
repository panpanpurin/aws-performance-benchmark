def apply_filters(df, filters):
   
    if not filters:
        return df

    # Iterate through each column and its filter condition
    for column, condition in filters.items():
        # If the condition is a dictionary, it contains one or more comparison operators
        if isinstance(condition, dict):
            for op, val in condition.items():
                # Apply greater than (>) filter
                if op == "$gt":
                    df = df[df[column] > val]
                # Apply less than (<) filter
                elif op == "$lt":
                    df = df[df[column] < val]
                # Apply equal to (==) filter
                elif op == "$eq":
                    df = df[df[column] == val]
                # Apply greater than or equal to (>=) filter
                elif op == "$gte":
                    df = df[df[column] >= val]
                # Apply less than or equal to (<=) filter
                elif op == "$lte":
                    df = df[df[column] <= val]
                # Apply not equal to (!=) filter
                elif op == "$ne":
                    df = df[df[column] != val]
        else:
            # If the condition is not a dictionary, use simple equality
            df = df[df[column] == condition]

    # Return the filtered DataFrame
    return df
