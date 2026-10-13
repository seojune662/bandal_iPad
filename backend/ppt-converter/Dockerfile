FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends python3 libreoffice-impress bubblewrap ca-certificates fonts-noto-cjk \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home converter
WORKDIR /app
COPY server.py /app/server.py
USER 10001:10001
EXPOSE 8080
CMD ["python3", "/app/server.py"]
