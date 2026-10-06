FROM ghcr.io/neirth/openlobster/openlobster:latest

# Remove the hardcoded mobile / viewport blocker in the embedded frontend bundle
USER root
RUN sed -i 's/r(e||n||i)};/r(false\&\&i);/g' /app/bin/openlobster
USER nonroot

EXPOSE 8080
ENTRYPOINT ["/app/bin/openlobster"]
CMD ["serve"]
