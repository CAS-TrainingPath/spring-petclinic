# 🐾 Spring PetClinic en Kubernetes — Despliegue Seguro

## 📑 Índice

- [Introducción](#introducción)
- [Objetivos del Ejercicio](#objetivos-del-ejercicio)
- [Arquitectura General](#arquitectura-general)
- [Estructura de Archivos](#estructura-de-archivos)
- [Medidas de Seguridad Implementadas](#medidas-de-seguridad-implementadas)
- [Componentes en Kubernetes](#componentes-en-kubernetes)
- [Despliegue de la Aplicación](#despliegue-de-la-aplicación)
- [Gestión de Imágenes Docker](#gestión-de-imágenes-docker)
- [Base de Datos MySQL](#base-de-datos-mysql)
- [Exposición del Servicio](#exposición-del-servicio)
- [Políticas de Red](#políticas-de-red)
- [Observabilidad y HealthChecks](#observabilidad-y-healthchecks)
- [Gestión del Ciclo de Vida](#gestión-del-ciclo-de-vida)
- [Troubleshooting](#troubleshooting)
- [Conclusión](#conclusión)

---

## Introducción

En este ejercicio se despliega la aplicación **Spring PetClinic** sobre un clúster **Kubernetes local (Minikube)**, siguiendo un enfoque **cloud-native** con especial énfasis en **seguridad desde el origen** (*security by design*).

El objetivo no es únicamente "hacer que funcione", sino construir un despliegue que aplique las capas de seguridad propias de un entorno real: aislamiento de credenciales, restricción de privilegios, limitación de recursos, control de tráfico de red y cumplimiento de estándares de seguridad de pods.

Cada decisión técnica tiene un **por qué** que se explica a lo largo de este documento.

---

## Objetivos del Ejercicio

- Desplegar **Spring PetClinic** en Kubernetes usando `Deployment` y `Service`
- Conectar la aplicación a una base de datos **MySQL** desplegada en el mismo clúster
- Gestionar credenciales de forma segura mediante **Kubernetes Secrets**
- Aplicar **SecurityContext** y **Pod Security Standards** para restringir privilegios
- Aislar el tráfico de red con **NetworkPolicies**
- Garantizar la persistencia de datos con un **PersistentVolumeClaim**
- Entender el **por qué** de cada medida de seguridad aplicada

---

## Arquitectura General

NodePort 8080 ⬆️

> - Namespace: `petclinic-app`
> - pod: `petclinic`
 Puerto ⬇️ 3306
> - pod: `mysql`
Volumen ⬇️ persistente
> - mysql-pvc (5Gi)  

---

## Estructura de Archivos

- mysql-deploy.yml: Deployment de MySQL
- mysql-service.yml: Service ClusterIP interno (solo accesible desde el clúster)
- pet-deploy.yml: Deployment de PetClinic
- pet-service.yml: Service NodePort para acceso externo
- red-petclinic.yml: NetworkPolicies de aislamiento de tráfico
- vol-persist.yml: PersistentVolumeClaim para datos de MySQL

---

## Medidas de Seguridad Implementadas

Esta sección explica todas las capas de seguridad aplicadas y el motivo de cada una.

### 1. Namespace dedicado

```bash
kubectl create namespace petclinic-app
kubectl config set-context --current --namespace=petclinic-app
```

**¿Por qué?** Desplegar en el namespace `default` mezcla recursos de distintas aplicaciones en el mismo espacio. Un namespace propio permite aislar los recursos, NetworkPolicies y Pod Security Standards únicamente a esta aplicación sin afectar al resto del clúster.

---

### 2. Credenciales en Kubernetes Secrets

En lugar de escribir contraseñas en texto plano en los YAMLs, todas las credenciales se almacenan en un Secret:

```bash
kubectl create secret generic mysql-credentials \
  --from-literal=mysql-root-password=OtraPasswordSegura456! \
  --from-literal=mysql-user=petclinic \
  --from-literal=mysql-password=TuPasswordSegura123! \
  --from-literal=mysql-database=petclinic \
  -n petclinic-app
```

Los pods referencian el Secret mediante `secretKeyRef` en lugar de `value`:

```yaml
env:
  - name: MYSQL_PASSWORD
    valueFrom:
      secretKeyRef:
        name: mysql-credentials
        key: mysql-password
```

**¿Por qué?** Las credenciales en texto plano en YAMLs suponen un riesgo crítico: cualquiera con acceso al repositorio de código o al clúster puede leerlas directamente. Los Secrets de Kubernetes almacenan los valores en Base64 y permiten controlar el acceso mediante RBAC. Además, desacoplan las credenciales del código, facilitando cambiarlas sin modificar ni redesplegar la aplicación.

---

### 3. SecurityContext en cada contenedor

Aplicado tanto en `mysql-deploy.yml` como en `pet-deploy.yml`:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 999          # uid del usuario mysql en mysql-deploy.yml
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  seccompProfile:
    type: RuntimeDefault
  capabilities:
    drop: ["ALL"]
```

**¿Por qué campo a campo?**

- `runAsNonRoot: true` — impide que el contenedor arranque como root. Un proceso root dentro de un contenedor puede, bajo ciertas configuraciones del kernel, escapar al nodo host. Esta restricción es la primera barrera contra esa escalada.

- `runAsUser: 999` (MySQL) / `1000` (PetClinic) — fuerza un UID concreto. Para MySQL se usa el 999 porque es el UID interno del usuario `mysql` dentro de la imagen oficial; si usára otro UID MySQL fallara al arrancar. (ya lo he comprobado🥲)

- `allowPrivilegeEscalation: false` — evita que un proceso dentro del contenedor adquiera más privilegios de los que tiene al arrancar.

- `readOnlyRootFilesystem: true` — monta el sistema de ficheros raíz del contenedor en modo solo lectura. Esto bloquea que un atacante que consiga ejecutar código en el contenedor pueda modificar binarios, instalar herramientas maliciosas o escribir scripts.

- `seccompProfile: RuntimeDefault` — aplica el perfil seccomp por defecto del runtime, que filtra las llamadas al sistema (syscalls) más peligrosas. Es obligatorio para cumplir con el Pod Security Standard `restricted`.

- `capabilities: drop: ["ALL"]` — elimina todas las Linux capabilities del proceso. Por defecto los contenedores heredan capacidades como `NET_RAW` (permite construir paquetes de red arbitrarios) o `SYS_CHROOT`. Eliminarlas todas reduce drásticamente la superficie de ataque.

---

### 4. Volúmenes emptyDir para escritura temporal

Con `readOnlyRootFilesystem: true`, los procesos que necesitan escribir en disco fallan si no tienen un punto de montaje con permisos de escritura. Se añaden volúmenes `emptyDir` solo donde es estrictamente necesario:

```yaml
# MySQL — necesita /tmp y el socket de mysqld
  volumeMounts:
    - name: mysql-data
      mountPath: /var/lib/mysql
    - name: tmp-dir
      mountPath: /tmp
    - name: run-dir
      mountPath: /var/run/mysqld
volumes:
  - name: mysql-data
    persistentVolumeClaim:
      claimName: mysql-pvc
  - name: tmp-dir
    emptyDir: {}
  - name: run-dir
    emptyDir: {}

# PetClinic — Spring Boot escribe en /tmp
volumeMounts:
  - name: tmp
    mountPath: /tmp
```

**¿Por qué?** `emptyDir` crea un directorio vacío con vida ligada al pod (se elimina cuando el pod muere). Permite la escritura temporal sin comprometer el sistema de ficheros raíz del contenedor. Es el mínimo privilegio necesario para que la aplicación funcione.

---

### 5. Límites de recursos

```yaml
resources:
  requests:
    cpu: "250m"
    memory: "512Mi"
  limits:
    cpu: "500m"
    memory: "1Gi"
```

**¿Por qué?** Sin límites, un pod puede consumir todos los recursos del nodo, degradando o tumbando el resto de aplicaciones (ataque de denegación de servicio interno, o simplemente un bug con fuga de memoria). Los `requests` garantizan recursos mínimos para el pod; los `limits` establecen el techo máximo que Kubernetes nunca permitirá superar.

---

### 6. PersistentVolumeClaim para MySQL

```yaml
# vol-persist.yml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
  namespace: petclinic-app
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
```

Referenciado en el deployment como:

```yaml
volumes:
  - name: mysql-data
    persistentVolumeClaim:
      claimName: mysql-pvc
```

**¿Por qué?** El volumen `emptyDir` original destruye todos los datos de MySQL cada vez que el pod se reinicia. Un PVC persiste los datos de forma independiente al ciclo de vida del pod, lo que es imprescindible para cualquier base de datos. Kubernetes gestiona el enlace entre el PVC y el almacenamiento físico del nodo.

---

### 7. NetworkPolicies de aislamiento

Definidas en `red-petclinic.yml`. Por defecto, todos los pods de un namespace pueden comunicarse entre sí libremente. Las NetworkPolicies restringen ese tráfico.

**Política de MySQL** — solo acepta conexiones entrantes desde petclinic, y no tiene salida a internet:

```yaml
spec:
  podSelector:
    matchLabels:
      app: mysql
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: petclinic
      ports:
        - protocol: TCP
          port: 3306
  egress: []
```

**Política de PetClinic** — acepta tráfico en el 8080, solo puede conectar a MySQL en 3306, y permite resolución DNS:

```yaml
spec:
  podSelector:
    matchLabels:
      app: petclinic
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: mysql
      ports:
        - protocol: TCP
          port: 3306
    - ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

**¿Por qué?** Si un atacante compromete el pod de PetClinic, sin NetworkPolicies podría desde ahí escanear y atacar cualquier otro pod del clúster. Con estas políticas, el movimiento lateral queda bloqueado: PetClinic solo puede hablar con MySQL y con el DNS interno, nada más. MySQL solo acepta conexiones de PetClinic, eliminando cualquier acceso directo desde el exterior o desde otros pods.

La regla de DNS (puerto 53) es necesaria porque Kubernetes resuelve nombres de servicio (`mysql`) mediante su DNS interno. Sin esta regla, PetClinic no podría resolver la dirección de MySQL aunque tuviera permiso para conectarse.

---

### 8. Pod Security Standards

```bash
kubectl label namespace petclinic-app \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted
```

**¿Por qué?** Esta etiqueta activa el modo `restricted` del Pod Security Admission controller de Kubernetes, que es el nivel más estricto del estándar oficial. Cualquier pod que no cumpla todos los requisitos de seguridad (runAsNonRoot, seccompProfile, drop ALL, etc.) es rechazado antes de crearse. Actúa como última línea de defensa que garantiza que ningún pod del namespace pueda saltarse las políticas de seguridad definidas.

---

## Componentes en Kubernetes

### mysql-service.yml — Service ClusterIP

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql
spec:
  type: ClusterIP
  selector:
    app: mysql
  ports:
    - port: 3306
      targetPort: 3306
```

`ClusterIP` expone MySQL únicamente dentro del clúster mediante la dirección IP interna y el nombre DNS `mysql`. Es imposible acceder a este servicio desde fuera del clúster, lo que protege la base de datos de exposición directa a internet.

---

### mysql-deploy.yml — Deployment de MySQL

Deployment completo con todas las medidas de seguridad:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
        - name: mysql
          image: mysql:9.6
          ports:
            - containerPort: 3306
          env:
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: mysql-root-password
            - name: MYSQL_USER
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: mysql-user
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: mysql-password
            - name: MYSQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: mysql-database
          securityContext:
            runAsNonRoot: true
            runAsUser: 999
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            seccompProfile:
              type: RuntimeDefault
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          volumeMounts:
            - name: mysql-data
              mountPath: /var/lib/mysql
            - name: tmp-dir
              mountPath: /tmp
            - name: run-dir
              mountPath: /var/run/mysqld
          livenessProbe:
            exec:
              command:
                - sh
                - -c
                - mysqladmin ping -h localhost -u petclinic -ppetclinic
            initialDelaySeconds: 30
            periodSeconds: 10
      volumes:
        - name: mysql-data
          persistentVolumeClaim:
            claimName: mysql-pvc
        - name: tmp-dir
          emptyDir: {}
        - name: run-dir
          emptyDir: {}
```

---

### pet-deploy.yml — Deployment de PetClinic

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: petclinic
spec:
  replicas: 1
  selector:
    matchLabels:
      app: petclinic
  template:
    metadata:
      labels:
        app: petclinic
    spec:
      containers:
        - name: petclinic
          image: petclinic:mini
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: SPRING_PROFILES_ACTIVE
              value: mysql
            - name: SPRING_DATASOURCE_URL
              value: jdbc:mysql://mysql:3306/petclinic
            - name: SPRING_DATASOURCE_USERNAME
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: mysql-user
            - name: SPRING_DATASOURCE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: mysql-password
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            seccompProfile:
              type: RuntimeDefault
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
            limits:
              cpu: "500m"
              memory: "1Gi"
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 10
      volumes:
        - name: tmp
          emptyDir: {}
```

`SPRING_DATASOURCE_URL` usa el nombre DNS interno `mysql` (nombre del Service de MySQL). Kubernetes resuelve este nombre automáticamente a la IP del pod de MySQL dentro del namespace.

---

### pet-service.yml — Service NodePort

```yaml
apiVersion: v1
kind: Service
metadata:
  name: petclinic
spec:
  type: NodePort
  selector:
    app: petclinic
  ports:
    - port: 8080
      targetPort: 8080
```

`NodePort` expone la aplicación en un puerto del nodo de Minikube, permitiendo el acceso desde el navegador del host. En un entorno de producción este servicio se sustituiría por un `Ingress` con TLS para cifrar el tráfico y evitar la exposición directa de puertos del nodo.

---

## Despliegue de la Aplicación

### Prerrequisitos

Tener Minikube en funcionamiento y la imagen `petclinic:mini` cargada:

```bash
minikube start
minikube image load petclinic:mini
```

### Paso 1 — Crear el namespace y el contexto

```bash
kubectl create namespace petclinic-app
kubectl config set-context --current --namespace=petclinic-app
```

### Paso 2 — Crear el Secret con las credenciales

```bash
kubectl create secret generic mysql-credentials \
  --from-literal=mysql-root-password=OtraPasswordSegura456! \
  --from-literal=mysql-user=petclinic \
  --from-literal=mysql-password=TuPasswordSegura123! \
  --from-literal=mysql-database=petclinic \
  -n petclinic-app
```

### Paso 3 — Aplicar Pod Security Standards

```bash
kubectl label namespace petclinic-app \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted
```

### Paso 4 — Aplicar los manifiestos en orden

El orden importa: el PVC y el Service de MySQL deben existir antes de que el pod de MySQL arranque, y MySQL debe estar listo antes de que PetClinic intente conectarse.

```bash
kubectl apply -f vol-persist.yml      # 1. Almacenamiento persistente
kubectl apply -f mysql-service.yml    # 2. DNS interno para MySQL
kubectl apply -f mysql-deploy.yml     # 3. Pod de MySQL
kubectl apply -f pet-service.yml      # 4. Exposición de PetClinic
kubectl apply -f pet-deploy.yml       # 5. Pod de PetClinic
kubectl apply -f red-petclinic.yml    # 6. Políticas de red
```

### Paso 5 — Verificar el arranque

```bash
kubectl get pods -n petclinic-app -w
```

Esperar a que ambos pods muestren `Running` y `Ready 1/1`. PetClinic tarda aproximadamente 35 segundos en arrancar.

### Paso 6 — Acceder a la aplicación

```bash
minikube service petclinic -n petclinic-app --url
```

Abre la URL devuelta en el navegador.

---

## Gestión de Imágenes Docker

Se usa una imagen propia en lugar de la imagen oficial de PetClinic:

```yaml
image: petclinic:mini
imagePullPolicy: IfNotPresent
```

`IfNotPresent` indica a Kubernetes que use la imagen local si ya existe en el nodo, sin intentar descargarla de un registry externo. En Minikube es necesario cargar la imagen previamente con `minikube image load`.

---

## Base de Datos MySQL

La aplicación conecta con MySQL usando el perfil Spring `mysql`:

```yaml
- name: SPRING_PROFILES_ACTIVE
  value: mysql
- name: SPRING_DATASOURCE_URL
  value: jdbc:mysql://mysql:3306/petclinic
```

`mysql` en la URL es el nombre del Service de Kubernetes, que actúa como nombre DNS interno. Kubernetes resuelve automáticamente ese nombre a la IP del pod de MySQL, sin necesidad de conocer la IP real.

---

## Exposición del Servicio

Para acceder a la aplicación desde el host:

```bash
# Obtener la URL
minikube service petclinic -n petclinic-app --url

# O abrir directamente en el navegador
minikube service petclinic -n petclinic-app
```

---

## Políticas de Red

Las NetworkPolicies implementadas crean un modelo de denegación por defecto: todo el tráfico no explícitamente permitido queda bloqueado.

El tráfico permitido se resume en:

| Origen    | Destino     | Puerto | Protocolo |
|--------   |---------    |--------|-----------|
| petclinic | mysql       | 3306   | TCP       |
| petclinic | DNS interno | 53     | UDP + TCP |
| exterior  | petclinic   | 8080   | TCP       |

Todo lo demás queda bloqueado automáticamente.

---

## Observabilidad y HealthChecks

Ambos deployments incluyen probes que permiten a Kubernetes gestionar el ciclo de vida de los pods de forma automática.

**MySQL** usa una probe de tipo `exec` que ejecuta `mysqladmin ping` para verificar que el motor de base de datos responde:

```yaml
livenessProbe:
  exec:
    command:
      - sh
      - -c
      - mysqladmin ping -h localhost -u petclinic -ppetclinic # Como se securiza esto por favor 😭🙏
  initialDelaySeconds: 30
  periodSeconds: 10
```

**PetClinic** usa probes HTTP contra el endpoint raíz:

```yaml
readinessProbe:
  httpGet:
    path: /
    port: 8080
  initialDelaySeconds: 30   # tiempo que tarda Spring Boot en arrancar
  periodSeconds: 5

livenessProbe:
  httpGet:
    path: /
    port: 8080
  initialDelaySeconds: 60
  periodSeconds: 10
```

La `readinessProbe` indica a Kubernetes cuándo el pod está listo para recibir tráfico. Mientras no pase, el Service no enruta peticiones a ese pod, evitando errores durante el arranque. La `livenessProbe` reinicia el pod automáticamente si la aplicación queda bloqueada pero el proceso sigue vivo.

---

## Gestión del Ciclo de Vida

### Parar la aplicación

**Opción A — Escalar a 0** (recomendada para sandbox, conserva el PVC):

```bash
kubectl scale deployment petclinic --replicas=0 -n petclinic-app
kubectl scale deployment mysql --replicas=0 -n petclinic-app
```

**Opción B — Eliminar todos los recursos**:

```bash
kubectl delete -f pet-deploy.yml -f pet-service.yml
kubectl delete -f mysql-deploy.yml -f mysql-service.yml
kubectl delete -f red-petclinic.yml
kubectl delete -f vol-persist.yml  # elimina también los datos
```

### Volver a levantar

**Tras parar Minikube:**

```bash
minikube start
```

**Tras escalar a 0:**

```bash
kubectl scale deployment mysql --replicas=1 -n petclinic-app
kubectl scale deployment petclinic --replicas=1 -n petclinic-app
```

**Tras eliminar recursos:**

```bash
kubectl apply -f vol-persist.yml
kubectl apply -f mysql-service.yml
kubectl apply -f mysql-deploy.yml
kubectl apply -f pet-service.yml
kubectl apply -f pet-deploy.yml
kubectl apply -f red-petclinic.yml
```

---

## Troubleshooting

### El pod entra en `CrashLoopBackOff`

```bash
kubectl logs deploy/petclinic -n petclinic-app
kubectl logs deploy/mysql -n petclinic-app
kubectl describe pod -l app=petclinic -n petclinic-app
```

Causas más frecuentes: el Secret no existe o alguna key no coincide, el PVC no pudo provisionarse, o Spring Boot no puede escribir en disco (añadir volumen `/tmp`).

### Error `ImagePullBackOff`

La imagen no está disponible en Minikube. Cargarla de nuevo:

```bash
minikube image load petclinic:mini
```

### `minikube service` da `SVC_UNREACHABLE`

El pod todavía no ha superado la readinessProbe. Esperar a que ambos pods estén `Ready 1/1`:

```bash
kubectl get pods -n petclinic-app -w
```

### El pod es rechazado al aplicar el manifiesto

Si el namespace tiene `pod-security.kubernetes.io/enforce=restricted`, cualquier pod que no cumpla el estándar es rechazado. Verificar que el `securityContext` incluye `seccompProfile`, `runAsNonRoot`, `allowPrivilegeEscalation: false` y `capabilities: drop: ["ALL"]`.

### Cambios no aplicados

Kubernetes es declarativo. Siempre aplicar los cambios con:

```bash
kubectl apply -f <archivo>.yml
```

---

## Conclusión

Este ejercicio demuestra cómo llevar Spring PetClinic de Docker a Kubernetes aplicando seguridad en todas las capas:

- **Secretos** en lugar de credenciales en texto plano
- **SecurityContext** para ejecutar sin privilegios de root
- **Filesystem de solo lectura** para bloquear modificaciones en tiempo de ejecución
- **Límites de recursos** para prevenir denegaciones de servicio internas
- **NetworkPolicies** para aislar el tráfico y bloquear movimiento lateral
- **PersistentVolumeClaim** para garantizar la durabilidad de los datos
- **Pod Security Standards** como capa de validación automática

Esta arquitectura es directamente extrapolable a cualquier aplicación Spring Boot moderna en Kubernetes, tanto en entornos locales como en cloud, añadiendo en producción un Ingress con TLS, RBAC, y monitorización con herramientas como Falco o Trivy.
