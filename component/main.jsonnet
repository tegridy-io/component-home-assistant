// main template for home-assistant
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.home_assistant;
local appName = 'home-assistant';

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

local defaultLabels = {
  'app.kubernetes.io/instance': 'home-assistant',
  'app.kubernetes.io/managed-by': 'commodore',
  'app.kubernetes.io/name': 'home-assistant',
};

// Deployment

local configMap = kube.ConfigMap('home-assistant-config') {
  metadata+: {
    labels+: defaultLabels,
  },
  data+: {
    'configuration.yaml': params.config.content,
  },
};

local configData = kube.PersistentVolumeClaim('home-assistant-config') {
  metadata+: {
    labels+: defaultLabels,
  },
  storageClass:: params.storage.class,
  storage:: params.storage.size,
};

local deployment = kube.Deployment(appName) {
  metadata+: {
    labels+: {
      'checksum/config': std.md5(std.manifestJsonMinified(configMap.data)),
    } + defaultLabels,
  },
  spec+: {
    replicas: params.replicaCount,
    template+: {
      spec+: {
        serviceAccountName: 'default',
        securityContext: {
          seccompProfile: { type: 'RuntimeDefault' },
        },
        initContainers_:: {
          [if params.config.enabled then 'copy']: kube.Container('copy') {
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
          },
        },
        containers_:: {
          default: kube.Container(appName) {
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
          },
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


// Service

local service = kube.Service('home-assistant') {
  metadata+: {
    labels+: defaultLabels,
  },
  target_pod:: deployment.spec.template,
};


// Monitoring

local serviceMonitor = kube._Object('monitoring.coreos.com/v1', 'ServiceMonitor', 'home-assistant') {
  metadata+: {
    labels+: defaultLabels,
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
  } + params.monitoring.service,
};


// Ingress

local ingress = kube._Object('networking.k8s.io/v1', 'Ingress', 'home-assistant') {
  metadata+: {
    [if params.ingress.tls.enabled then 'annotations']: { 'cert-manager.io/cluster-issuer': params.ingress.tls.issuer },
    labels+: defaultLabels,
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
  '10_deployment': deployment,
  '10_config': [ configMap, configData ],
  '10_service': service,
  [if params.monitoring.enabled then '20_monitoring']: serviceMonitor,
  [if params.ingress.enabled then '30_ingress']: ingress,
  //   '10_rbac': [ serviceAccount, clusterRole, clusterRoleBinding, role, roleBinding ],
}
