FROM alpine:3.19

RUN apk add --no-cache bash grep

WORKDIR /app

COPY . /app

RUN chmod +x /app/scripts/*.sh /app/tests/*.sh /app/tests/mocks/*

CMD ["bash", "-c", "/app/tests/test_deploy.sh && /app/tests/test_cleanup.sh"]
