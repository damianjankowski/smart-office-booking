# ------ STAGE 1: build dependencies ------
FROM python:3.13-slim AS build

WORKDIR /app

RUN apt-get update && apt-get install -y zip && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY parking.py .

RUN zip -r function.zip parking.py && \
    pip install --no-cache-dir -r requirements.txt -t ./package && \
    cd package && \
    zip -r ../function.zip . && \
    cd ..

# ------ STAGE 2: export package ------
FROM busybox AS export
COPY --from=build /app/function.zip /out/ 