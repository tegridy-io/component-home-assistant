// main template for home-assistant
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.home_assistant;
local app_name = inv.parameters._instance;

local namespace = kube.Namespace(params.namespace.name) {
  metadata+: {
    annotations+: {

    } + params.namespace.annotations,
    labels+: {
      'app.kubernetes.io/managed-by': 'commodore',
      'app.kubernetes.io/name': params.namespace.name,
    } + params.namespace.labels,
  },
};

local labelsHomeAssistant = {
  'app.kubernetes.io/instance': app_name,
  'app.kubernetes.io/component': 'application',
};

local labelsDatabase = {
  'app.kubernetes.io/instance': app_name,
  'app.kubernetes.io/component': 'database',
};


// Containers

local containerConfigCopy = kube.Container('copy-config') {
  image: '%(registry)s/%(repository)s:%(tag)s' % params.images.kubectl,
  cmd: [ 'sh' ],
  args: [
    '-c',
    'cp -Rf /from/* /config/',
  ],
  volumeMounts_:: {
    config: {
      mountPath: '/from',
    },
    data: {
      mountPath: '/config',
    },
  },
};

local containerHomeAssistant = kube.Container('home-assistant') {
  image: '%(registry)s/%(repository)s:%(tag)s' % params.images.home_assistant,
  env_:: {
    TC: 'UTC',
  },
  ports_:: {
    http: { containerPort: 8123 },
  },
  resources: params.resources.home_assistant,
  securityContext: {
    allowPrivilegeEscalation: false,
    capabilities: { drop: [ 'ALL' ] },
  },
  livenessProbe: {
    tcpSocket: { port: 8123 },
    initialDelaySeconds: 0,
    failureThreshold: 3,
    timeoutSeconds: 1,
    periodSeconds: 10,
  },
  readinessProbe: {
    tcpSocket: { port: 8123 },
    initialDelaySeconds: 0,
    failureThreshold: 3,
    timeoutSeconds: 1,
    periodSeconds: 10,
  },
  startupProbe: {
    tcpSocket: { port: 8123 },
    initialDelaySeconds: 0,
    failureThreshold: 30,
    timeoutSeconds: 1,
    periodSeconds: 5,
  },
  volumeMounts_:: {
    data: {
      mountPath: '/config',
    },
  },
};

local containerDatabase = kube.Container('influxdb') {
  image: '%(registry)s/%(repository)s:%(tag)s' % params.images.influxdb,
  env_:: {
    DOCKER_INFLUXDB_INIT_MODE: 'setup',
    DOCKER_INFLUXDB_INIT_USERNAME: 'homeassistant',
    DOCKER_INFLUXDB_INIT_PASSWORD: { secretKeyRef: { key: 'password', name: 'influxdb-admin' } },
    DOCKER_INFLUXDB_INIT_ORG: 'homeassistant',
    DOCKER_INFLUXDB_INIT_BUCKET: 'homeassistant',
    DOCKER_INFLUXDB_INIT_RETENTION: params.influxdb.retention,
    DOCKER_INFLUXDB_INIT_ADMIN_TOKEN: { secretKeyRef: { key: 'token', name: 'influxdb-admin' } },
    INFLUXD_BOLT_PATH: '/var/lib/influxdb2/influxd.bolt',
    INFLUXD_ENGINE_PATH: '/var/lib/influxdb2',
  },
  ports_:: {
    http: { containerPort: 8086 },
  },
  resources: params.resources.influxdb,
  securityContext: {
    allowPrivilegeEscalation: false,
    // capabilities: { drop: [ 'ALL' ] },
  },
  livenessProbe: {
    failureThreshold: 3,
    httpGet: {
      path: '/health',
      port: 'http',
      scheme: 'HTTP',
    },
    initialDelaySeconds: 0,
    periodSeconds: 10,
    timeoutSeconds: 1,
  },
  readinessProbe: {
    failureThreshold: 3,
    httpGet: {
      path: '/health',
      port: 'http',
      scheme: 'HTTP',
    },
    initialDelaySeconds: 0,
    periodSeconds: 10,
    successThreshold: 1,
    timeoutSeconds: 1,
  },
  volumeMounts_:: {
    data: {
      mountPath: '/var/lib/influxdb2',
    },
    etc: {
      mountPath: '/etc/influxdb2',
    },
  },
};

// Home-Assistant

local varsHomeAssistant = {
  prometheus: if params.prometheus.enabled then |||
    prometheus:
      requires_auth: false
  ||| else '',
  influxdb: if params.influxdb.enabled then |||
    influxdb:
      api_version: 2
      ssl: false
      host: influxdb.svc
      port: 8086
      token: aiCah1Ahw6Lieb9ohsh9Tiesh1wuNgei
      organization: homeassistant
      bucket: homeassistant
      tags:
        source: HA
      tags_attributes:
        - friendly_name
      default_measurement: units
  ||| else '',
};

local configHomeAssistant = kube.ConfigMap('home-assistant-config') {
  metadata+: {
    labels+: {
      'app.kubernetes.io/managed-by': 'commodore',
    } + labelsHomeAssistant,
  },
  data+: {
    'configuration.yaml': |||
      # Loads default set of integrations. Do not remove.
      default_config:

      # Home Assistat configuration.
      http:
        use_x_forwarded_for: true
        trusted_proxies:
        - 10.128.0.0/14
        ip_ban_enabled: true
        login_attempts_threshold: 5

      # Load frontend themes from the themes folder
      frontend:
        themes: !include_dir_merge_named themes
      automation: !include automations.yaml
      script: !include scripts.yaml
      scene: !include scenes.yaml

      # Enable websockets.
      websocket_api:

      # Enable prometheus
      %(prometheus)s

      # Enable influxdb
      %(influxdb)s

    ||| % varsHomeAssistant + params.config.extra,
  },
};

local pvcHomeAssistant = kube.PersistentVolumeClaim('home-assistant-config') {
  metadata+: {
    labels+: {
      'app.kubernetes.io/managed-by': 'commodore',
    } + labelsHomeAssistant,
  },
  spec+: {
    accessModes: [ params.storage.home_assistant.mode ],
  },
  storageClass:: params.storage.home_assistant.class,
  storage:: params.storage.home_assistant.size,
};

local deployHomeAssistant = kube.Deployment('home-assistant') {
  metadata+: {
    labels+: {
      'app.kubernetes.io/managed-by': 'commodore',
      'checksum/config': std.md5(std.manifestJsonMinified(configHomeAssistant.data)),
    } + labelsHomeAssistant,
  },
  spec+: {
    replicas: params.replicaCount,
    selector: {
      matchLabels: labelsHomeAssistant,
    },
    template+: {
      metadata: {
        labels: labelsHomeAssistant,
      },
      spec+: {
        serviceAccountName: 'default',
        securityContext: {
          seccompProfile: { type: 'RuntimeDefault' },
        },
        containers_:: {
          default: containerHomeAssistant,
        },
        initContainers_:: {
          [if params.config.enabled then 'copy-config']: containerConfigCopy,
        },
        volumes_:: {
          config: {
            configMap: {
              name: 'home-assistant-config',
            },
          },
          data: {
            persistentVolumeClaim: {
              claimName: 'home-assistant-config',
            },
          },
        },
      },
    },
  },
};

local serviceHomeAssistant = kube.Service('home-assistant') {
  metadata+: {
    labels+: {
      'app.kubernetes.io/managed-by': 'commodore',
    } + labelsHomeAssistant,
  },
  target_pod:: deployHomeAssistant.spec.template,
};


// InfluxDB

local secretDatabase = kube.Secret('influxdb-admin') {
  metadata+: {
    labels+: {
      'app.kubernetes.io/managed-by': 'commodore',
    } + labelsDatabase,
  },
  data_:: {
    password: 'oN1ee5Diesahghai4Foon2ivo4ieJohj',
    token: 'aiCah1Ahw6Lieb9ohsh9Tiesh1wuNgei',
  },
};

local pvcDatabase = kube.PersistentVolumeClaim('influxdb-data') {
  metadata+: {
    labels+: {
      'app.kubernetes.io/managed-by': 'commodore',
    } + labelsDatabase,
  },
  spec+: {
    accessModes: [ params.storage.influxdb.mode ],
  },
  storageClass:: params.storage.influxdb.class,
  storage:: params.storage.influxdb.size,
};

local deployDatabase = kube.Deployment('influxdb') {
  metadata+: {
    labels+: {
      'app.kubernetes.io/managed-by': 'commodore',
    } + labelsDatabase,
  },
  spec+: {
    replicas: 1,
    selector: {
      matchLabels: labelsDatabase,
    },
    template+: {
      metadata: {
        labels: labelsDatabase,
      },
      spec+: {
        serviceAccountName: 'default',
        securityContext: {
          seccompProfile: { type: 'RuntimeDefault' },
        },
        containers_:: {
          default: containerDatabase,
        },
        volumes_:: {
          data: {
            persistentVolumeClaim: {
              claimName: 'influxdb-data',
            },
          },
          etc: {
            emptyDir: {},
          },
        },
      },
    },
  },
};

local serviceDatabase = kube.Service('influxdb') {
  metadata+: {
    labels+: {
      'app.kubernetes.io/managed-by': 'commodore',
    } + labelsDatabase,
  },
  target_pod:: deployDatabase.spec.template,
};


// Monitoring

local serviceMonitor = kube._Object('monitoring.coreos.com/v1', 'ServiceMonitor', 'home-assistant') {
  metadata+: {
    labels+: {
      'app.kubernetes.io/managed-by': 'commodore',
    } + labelsHomeAssistant,
  },
  spec+: {
    selector: {
      matchLabels: {
        name: 'home-assistant',
      },
    },
    endpoints: [ {
      path: '/api/prometheus',
      port: 'http',
      scheme: 'http',
      interval: '10s',
    } ],
  } + params.prometheus.service,
};


// Ingress

local ingress = kube._Object('networking.k8s.io/v1', 'Ingress', 'home-assistant') {
  metadata+: {
    [if params.ingress.tls.enabled then 'annotations']: { 'cert-manager.io/cluster-issuer': params.ingress.tls.issuer },
    labels+: {
      'app.kubernetes.io/managed-by': 'commodore',
    } + labelsHomeAssistant,
  },
  spec+: {
    rules: [ {
      host: params.ingress.host,
      http: {
        paths: [ {
          backend: {
            service: {
              name: 'home-assistant',
              port: {
                name: 'http',
              },
            },
          },
          path: '/',
          pathType: 'Prefix',
        }, {
          // deactivate metrics on ingress
          backend: {
            service: {
              name: 'home-assistant',
              port: {
                number: 8080,
              },
            },
          },
          path: '/api/prometheus',
          pathType: 'Prefix',
        } ],
      },
    } ],
    [if params.ingress.tls.enabled then 'tls']: [ {
      hosts: [ params.ingress.host ],
      secretName: 'home-assistant-tls',
    } ],
  },
};

// Define outputs below
{
  '00_namespace': namespace,
  '10_deployment': [ configHomeAssistant, pvcHomeAssistant, deployHomeAssistant ],
  '10_service': serviceHomeAssistant,
  [if params.prometheus.enabled then '10_monitoring']: serviceMonitor,
  [if params.influxdb.enabled then '20_deployment']: [ secretDatabase, pvcDatabase, deployDatabase ],
  [if params.influxdb.enabled then '20_service']: serviceDatabase,
  [if params.ingress.enabled then '50_ingress']: ingress,
}
