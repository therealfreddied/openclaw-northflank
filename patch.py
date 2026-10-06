with open("/app/bin/openlobster", "rb") as f:
    data = f.read()

target = b"r(e||n||i)};"
assert data.count(target) == 1, f"target match count: {data.count(target)}"
patched = data.replace(target, b"r(false&&i);")

with open("/app/bin/openlobster", "wb") as f:
    f.write(patched)

print("Mobile blocker permanently disabled!")
