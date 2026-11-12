FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg libgomp1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY backend/requirements.txt backend/requirements.lock.txt backend/
RUN pip install --no-cache-dir -r backend/requirements.txt -c backend/requirements.lock.txt
COPY backend backend
COPY build/web build/web
COPY web/generate_offline_manifest.py web/generate_offline_manifest.py
RUN python web/generate_offline_manifest.py build/web
RUN useradd -u 10001 -m sera && mkdir /data && chown sera:sera /data
USER sera
ENV PYTHONUNBUFFERED=1 SERA_DB=/data/sera.sqlite3
EXPOSE 8787 8790
CMD ["python","backend/server.py","--host","0.0.0.0","--db","/data/sera.sqlite3","--web-dir","build/web"]
