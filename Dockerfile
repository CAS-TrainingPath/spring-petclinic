# syntax=docker/dockerfile:1

FROM eclipse-temurin:21-jdk-jammy AS build

WORKDIR /build

#descargar maven y las INSTRUCCIONES DE COMO SE DEFINE EL PROYECTO
COPY .mvn/ .mvn
COPY mvnw pom.xml ./

# descargar dependencias (cacheable)
RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw -B dependency:go-offline

# copiar código
COPY src ./src

# compilar aplicación
RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw -B package -DskipTests

#IMAGEN FINAL
FROM eclipse-temurin:21-jre-jammy

#Actualizar paquetes
RUN apt-get update && apt-get upgrade -y \
    && apt-get remove -y --purge gnupg gnupg2 gpg gpg-agent gpgv \
       gpgconf gpgsm gpg-wks-client gpg-wks-server dirmngr gnupg-l10n gnupg-utils \
       wget \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# crear usuario seguro
RUN adduser \
    --disabled-password \
    --gecos "" \
    --no-create-home \
    appuser

USER appuser

# copiar jar compilado de la anterior imagen
COPY --from=build /build/target/*.jar app.jar

# puerto de spring
EXPOSE 8080

# Explica porque ENTRYPOINT y no CMD
ENTRYPOINT ["java","-jar","/app/app.jar"]
