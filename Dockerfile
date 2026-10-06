FROM python:3.11-alpine AS patcher
COPY --from=ghcr.io/neirth/openlobster/openlobster:latest /app /app
RUN python3 -c '\
with open("/app/bin/openlobster", "rb") as f:\
    data = f.read()\
target = b"r(e||n||i)};"\
assert data.count(target) == 1, f"Count: {data.count(target)}"\
patched = data.replace(target, b"r(!1);/*x*/}")\
with open("/app/bin/openlobster", "wb") as f:\
    f.write(patched)\
print("Binary cleanly patched with valid JS syntax!")\
'

FROM ghcr.io/neirth/openlobster/openlobster:latest
COPY --from=patcher /app/bin/openlobster /app/bin/openlobster

EXPOSE 8080
ENTRYPOINT ["/app/bin/openlobster"]
CMD ["serve"]
