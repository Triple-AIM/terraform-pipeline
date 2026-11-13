# A path relative to the repository, in its one plain form: no `.` or `..`
# parts, and no extra slashes. Paths are compared as text, so a path in
# another form would never match.
def clean: type == "string" and (split("/") | all(.[]; . != "" and . != "." and . != ".."));
