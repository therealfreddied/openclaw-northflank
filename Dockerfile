FROM ghcr.io/neirth/openlobster/openlobster:latest

# Cleanly replace MobileBlocker isMobile check: r(e||n||i)}; -> r(!1)};/*x*/
USER root
RUN sed -i 's/r(e||n||i)};/r(!1)};\/\*x\*\//g' /app/bin/openlobster
USER nonroot

EXPOSE 8080
ENTRYPOINT ["/app/bin/openlobster"]
CMD ["serve"]
