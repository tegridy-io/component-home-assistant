// main template for home-assistant
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.home_assistant;
local appName = 'home-assistant';

local namespace = kube.Namespace(params.namespace) {
  metadata+: {
    labels+: {
      'app.kubernetes.io/name': params.namespace,
    },
  },
};

// Deployment

local deployment = kube.Deployment(appName) {
  spec+: {
    replicas: params.replicaCount,
    template+: {
      spec+: {
        serviceAccountName: 'default',
        securityContext: {
          seccompProfile: { type: 'RuntimeDefault' },
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
              config: {
                mountPath: '/config',
                subPath: 'configuration.yaml',
              },
            },
          },
        },
        volumes_:: {
          data: {
            persistentVolumeClaim: 'home-assistant-data',
          },
          config: {
            configMap: {
              name: 'home-assistant-config',
              //   items: [
              //     {
              //       key: 'configuration.yaml',
              //       path: 'configuration.yaml',
              //     },
              //   ],
              //   defaultMode: 420,
              //   optional: true,
            },
          },
        },
      },
    },
  },
};

// Define outputs below
{
  '00_namespace': namespace,
  '10_deployment': deployment,
  //   '10_service': service,
  //   '10_rbac': [ serviceAccount, clusterRole, clusterRoleBinding, role, roleBinding ],
}
