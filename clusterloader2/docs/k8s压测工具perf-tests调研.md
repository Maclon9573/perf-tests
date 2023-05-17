# k8s压测工具perf-tests调研

## clusterloader2

### 简介

ClusterLoader2(CL2)是一个“自带 yaml”的 Kubernetes 负载测试工具，它是一个官方的 K8可伸缩性和性能测试框架。CL2测试是使用yaml格式的半声明式范例编写的。一个测试定义了：

- 集群应该处于的一组状态(例如，我想运行10k个pods，2k个cluster-ip services，5个 daemon-set，等等) 
- 指定了应该达到给定状态的速度(例如 pod 吞吐量)
- 哪些性能特征应该被度量

最后，CL2测试使用Prometheus提供了集群可观测性方法。

架构设计：https://github.com/kubernetes/perf-tests/blob/master/clusterloader2/docs/design.md

### 编译

```
git clone git@github.com:kubernetes/perf-tests.git
cd perf-tests
export GO111MODULE="on"
go build -o clusterloader2 ./cmd/clusterloader.go
```

### 如何使用

See [Getting started](https://github.com/kubernetes/perf-tests/blob/master/clusterloader2/docs/GETTING_STARTED.md) guide if you are new user of ClusterLoader.

#### 启动参数

##### 必需参数

- kubeconfig - kubeconfig文件路径
- testconfig - 测试配置文件路径, 可以多次使用
- provider - 集群provider, 可以是gce, gke, kind, kubemark, aws, local, vsphere, skeleton

##### 可选参数

- nodes - 集群节点数,如果未指定,则为集群所有可调度的节点总数
- report-dir - 生成的报告的存放路径
- mastername - master节点名称
- masterip - master节点DNS名称或IP
- testoverrides - overrides文件路径
- kubelet-port - kubelet使用的端口(*默认: 10250*)

### 配置说明

测试配置文件config.yaml。这个测试会做以下事情：

- 创建一个命名空间
- 在该命名空间下创建一个有10个pods的deployment
- 测量这些pod的启动延迟

```yaml
name: test

namespace:
  number: 1

tuningSets:
- name: Uniform1qps
  qpsLoad:
    qps: 1

steps:
- name: Start measurements
  measurements:
  - Identifier: PodStartupLatency
    Method: PodStartupLatency
    Params:
      action: start
      labelSelector: group = test-pod
      threshold: 20s
  - Identifier: WaitForControlledPodsRunning
    Method: WaitForControlledPodsRunning
    Params:
      action: start
      apiVersion: apps/v1
      kind: Deployment
      labelSelector: group = test-deployment
      operationTimeout: 120s
- name: Create deployment
  phases:
  - namespaceRange:
      min: 1
      max: 1
    replicasPerNamespace: 1
    tuningSet: Uniform1qps
    objectBundle:
    - basename: test-deployment
      objectTemplatePath: "deployment.yaml"
      templateFillMap:
        Replicas: 10
- name: Wait for pods to be running
  measurements:
  - Identifier: WaitForControlledPodsRunning
    Method: WaitForControlledPodsRunning
    Params:
      action: gather
- name: Measure pod startup latency
  measurements:
  - Identifier: PodStartupLatency
    Method: PodStartupLatency
    Params:
      action: gather
```

首先，定义测试名称:

```
name: test
```

CL2将自动创建名称空间，但是我们需要指定需要多少名称空间:

```
namespace:
  number: 1
```

接下来，我们需要指定 TuningSet。TuningSet 描述如何执行操作。在我们的示例中，只有1个deployment，因此将只有1个操作要执行。在这种情况下，tuningSet 并不真正影响状态之间的转换。

```
tuningSets:
- name: Uniform1qps
  qpsLoad:
    qps: 1
```

测试定义由步骤列表组成。一个步骤可以是状态(Phrases)或度量(Measurement，[当前支持的度量](https://github.com/kubernetes/perf-tests/blob/master/clusterloader2/README.md#measurement))的集合。状态定义了集群应该达到的状态，度量允许测量某物或等待某物。

我们的第一步是启动两个测量。我们希望开始测量pod启动延迟，并进行等待所有pod处于运行状态的测量。将"action"字段设置为"start"开始执行度量。对于这两个测量，我们需要指定 label 选择器，这样它们就知道应该测量哪些pod。PodStartupLatency 也采用阈值。如果第99百分位的延迟超过这个阈值，测试就会失败。

```
steps:
- name: Start measurements
  measurements:
  - Identifier: PodStartupLatency
    Method: PodStartupLatency //通过方法名和下面的action判断要执行什么度量以及度量的动作
    Params:
      action: start
      labelSelector: group = test-pod
      threshold: 20s  //设置度量方法的阈值，超过此值，则该项度量被认定为失败
  - Identifier: WaitForControlledPodsRunning
    Method: WaitForControlledPodsRunning
    Params:
      action: start
      apiVersion: apps/v1
      kind: Deployment
      labelSelector: group = test-deployment
      operationTimeout: 120s
```

一旦我们创建了这两个度量，我们就可以创建deployment了。我们需要指定希望在哪些名称空间中创建这个deployment，每个名称空间中有多少个这样的deployment。此外，我们还需要为deployment指定模板，还有deployment的副本数量。

```
- name: Create deployment
  phases:
  - namespaceRange:
      min: 1
      max: 1
    replicasPerNamespace: 1
    tuningSet: Uniform1qps
    objectBundle:
    - basename: test-deployment
      objectTemplatePath: "deployment.yaml"
      templateFillMap:
        Replicas: 10
```

等待这个deployment中的 pods 处于运行状态:

```
- name: Wait for pods to be running
  measurements:
  - Identifier: WaitForControlledPodsRunning
    Method: WaitForControlledPodsRunning
    Params:
      action: gather
```

最后收集 PodStartupLatency 的结果:

```
- name: Measure pod startup latency
  measurements:
  - Identifier: PodStartupLatency
    Method: PodStartupLatency
    Params:
      action: gather
```

### 执行测试

运行以下命令，开始测试：

```
./clusterloader2 --testconfig=config.yaml --provider=local --kubeconfig=${HOME}/.kube/config --v=2
```

测试数据示例：

```
{
  "data": {
    "Perc50": 7100.534796,
    "Perc90": 8702.523037,
    "Perc99": 9122.894555
  },
  "unit": "ms",
  "labels": {
    "Metric": "pod_startup"
  }
},
```

测试结果：

```
--------------------------------------------------------------------------------
Test Finished
Test: ./config.yaml
Status: Success
--------------------------------------------------------------------------------
```

更多测试可使用[perf-tests](https://github.com/kubernetes/perf-tests)/[clusterloader2](https://github.com/kubernetes/perf-tests/tree/master/clusterloader2)/[testing](https://github.com/kubernetes/perf-tests/tree/master/clusterloader2/testing)目录下的配置

### 其他

**config.yaml中的变量语法：**

1. `{{$DENSITY_RESOURCE_CONSTRAINTS_FILE := DefaultParam .DENSITY_RESOURCE_CONSTRAINTS_FILE ""}}` means the parameter `DENSITY_RESOURCE_CONSTRAINTS_FILE` is **default to** "" if it is not set. You can set it manually to override its default value
2. `{{$MIN_LATENCY_PODS := 300}}` just means setting the parameter to 300
3. `{{$namespaces := DivideInt .Nodes $NODES_PER_NAMESPACE}}` means the number of namespaces is euqal to `floor(nodes/node_per_namespace)`. NOTE that `.Nodes` **MUST NOT** be less than `.NODES_PER_NAMESPACE`
4. `{{$podsPerNamespace := MultiplyInt $PODS_PER_NODE $NODES_PER_NAMESPACE}}` is similar to grammer 3, but multiplying the params
5. `{{$saturationDeploymentHardTimeout := MaxInt $saturationDeploymentTimeout 1200}}` means `max(saturationDeploymentTimeout, 1200)`

**latency pods**

- latency pods = namespaces * latencyReplicas
- namespaces = nodes / nodes per namespace
- nodes = avialable kubernetes nodes your cluster has
- latencyReplicas = max(MIN LATENCY PODS, nodes) / namespaces

**saturation pods**

- saturation pods = namespaces * pods per namespace, this formula can be found in **Creating Saturation pods** step
- pods per namespace = pods per node * nodes per namespace
- see the calculation of namespaces and nodes per namespace above in the part of **latency pods**



#### Overrides

Overrides allow to inject new variables values to the template.
Many tests define input parameters. Input parameter is a variable that potentially will be provided by the test framework. Cause input parameters are optional, each reference has to be opaqued with `DefaultParam` function that will handle case if given variable doesn't exist.
Example of overrides can be found here: [overrides](https://github.com/kubernetes/perf-tests/blob/master/clusterloader2/testing/density/scheduler/pod-affinity/overrides.yaml)

##### Passing environment variables

Instead of using overrides in file, it is possible to depend on environment variables. Only variables that start with `CL2_` prefix will be parsed and available in script.

Environment variables can be used with `DefaultParam` function to provide sane default values.

**Setting variables in shell**

```
export CL2_ACCESS_TOKENS_QPS=5
```

**Usage from test definition**

```
{{$qpsPerToken := DefaultParam .CL2_ACCESS_TOKENS_QPS 0.1}}
```

### 问题

1. 报错

```
W0419 10:34:17.437784    9315 simple_test_executor.go:174] Got errors during step execution: [measurement call TestMetrics - TestMetrics error: [action gather failed for SchedulingMetrics measurement: the server is currently unable to handle the request (get pods https:kube-scheduler-test-cluster-control-plane:10259)]]
```

![image-20230421165829555](/Users/mcll/Library/Application Support/typora-user-images/image-20230421165829555.png)

对应代码perf-tests/clusterloader2/pkg/measurement/common/scheduler_latency.go:303

```go
body, err := c.CoreV1().RESTClient().Verb(opUpper).
			Namespace(metav1.NamespaceSystem).
			Resource("pods").
			Name(fmt.Sprintf("https:kube-scheduler-%v:%v", masterName, kubeSchedulerPort)).
			SubResource("proxy").
			Suffix("metrics").
			Do(ctx).Raw()

		if err != nil {
			klog.Errorf("Send request to scheduler failed with err: %v", err)
			return "", err
		}
```

**问题原因**：

kube-scheduler使用127.0.0.1这个ip启动的服务，使用上面客户端会请求pod的clusterIP，所以找不到对应服务。

**解决方法**：

将kube-scheduler的bind address改为0.0.0.0，重启kubelet或kube-scheduler的容器

可使用以下命令测试是否成功

```
kubectl prxoy &
curl 127.0.0.1:8001/api/v1/namespaces/kube-system/pods/https:kube-scheduler-k8s-master:10259/proxy/metrics
```

2. 使用kind创建集群前，如果本地环境配置了http代理，需要清空代理:

```shell
export https_proxy="" && export http_proxy=""
```

3. 可以先使用docker pull获取镜像，以免在使用kind创建集群时，一直卡在拉取镜像阶段

```
docker pull registry.k8s.io/e2e-test-images/agnhost:2.32
```

如果无法下载上面的镜像，可以尝试下面的镜像，并将perf-tests/clusterloader2/execservice/manifest/exec_deployment.yaml中的镜像替换

```
docker pull e2eteam/agnhost:2.26
```

4. APIAvailability中api server的端口在代码中为443，clusterloader2/pkg/measurement/common/api_availability_measurement.go:98
