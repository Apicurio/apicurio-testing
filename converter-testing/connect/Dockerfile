## Stage 1: Download the Apicurio Registry converter distribution
FROM eclipse-temurin:17-jre AS downloader

ARG APICURIO_VERSION=3.0.7.Final

RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /converter && \
    cd /tmp && \
    echo "Downloading Apicurio Registry Connect Converter v${APICURIO_VERSION}..." && \
    curl -L -f -o converter.tar.gz \
      "https://repo1.maven.org/maven2/io/apicurio/apicurio-registry-distro-connect-converter/${APICURIO_VERSION}/apicurio-registry-distro-connect-converter-${APICURIO_VERSION}-converter.tar.gz" && \
    tar -xzf converter.tar.gz -C /converter && \
    rm converter.tar.gz && \
    echo "Converter contents:" && \
    ls -la /converter/

## Stage 2: Build the Kafka Connect image with the converter plugin
ARG KAFKA_VERSION=3.9.1
FROM apache/kafka:${KAFKA_VERSION}

USER root

# Copy the converter JARs from the downloader stage
COPY --from=downloader /converter /opt/kafka/connect-plugins/apicurio-converter

# Copy custom entrypoint that starts Connect in distributed mode
COPY start-connect.sh /opt/kafka/start-connect.sh
RUN chmod +x /opt/kafka/start-connect.sh

RUN echo "Apicurio converter plugin installed:" && \
    ls -la /opt/kafka/connect-plugins/apicurio-converter/

USER appuser

EXPOSE 8083

CMD ["/opt/kafka/start-connect.sh"]
