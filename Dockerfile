FROM python:3.11-alpine AS patcher
COPY --from=ghcr.io/neirth/openlobster/openlobster:latest /app /app
COPY patch.py /patch.py
RUN python3 /patch.py

FROM ghcr.io/neirth/openlobster/openlobster:latest
COPY --from=patcher /app/bin/openlobster /app/bin/openlobster
