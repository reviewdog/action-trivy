FROM alpine:latest

RUN apk add --no-cache curl

COPY . /app

WORKDIR /app

#HEALTHCHECK --interval=30s --timeout=3s \
#    CMD curl -f http://localhost/ || exit 1

CMD [ "python", "app.py" ]
