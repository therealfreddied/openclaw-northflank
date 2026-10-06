FROM python:3.11-alpine AS patcher
COPY --from=ghcr.io/neirth/openlobster/openlobster:latest /app /app
RUN python3 -c '\
with open("/app/bin/openlobster", "rb") as f:\
    data = f.read()\
target = b"r(e||n||i)};"\
assert data.count(target) == 1, f"target match count: {data.count(target)}"\
patched = data.replace(target, b"r(false&&i);")\
with open("/app/bin/openlobster", "wb") as f:\
    f.write(patched)\
print("Mobile blocker permanently disabled!")\
'

FROM ghcr.io/neirth/openlobster/openlobster:latest
COPY --from=patcher /app/bin/openlobster /app/bin/openlobster
