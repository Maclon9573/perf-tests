# kube-apiserver CL2测试

###**参数配置**
配置文档参考`clusterloader2/testing/density/apiserver.yaml`

**节点数量**：通过nodes参数指定，如果不指定，则获取集群中可调度的并且没有Taints的节点总数

**namespace数量**：`{{$namespaces := DivideInt .Nodes $NODES_PER_NAMESPACE}}`建议每个命名空间分配一个nodes，即NODES_PER_NAMESPACE为1，便于计算

**workload数量**：phases.replicasPerNamespace

**单个workload的pod数量**：phases.ObjectBundle.templateFillMap.Replicas

**workload模版**：phases.ObjectBundle.objectTemplatePath

###**测试命令示例**

```
go run cmd/clusterloader.go --enable-prometheus-server=true --prometheus-apiserver-scrape-port=6443 --prometheus-storage-class-provisioner="docker.io/hostpath" --prometheus-pvc-storage-class=hostpath  --nodes=3 --testconfig=./testing/density/apiserver.yaml --provider=local --kubeconfig=${HOME}/.kube/config --v=2 --report-dir=./reports --tear-down-prometheus-server=false 2>&1|tee ./cl2.log
```
###配置解析
**tuningSets**

qpsLoad: 每秒创建n个pod

```
func (ql *qpsLoad) Execute(actions []func()) {
   sleepDuration := time.Duration(int(float64(time.Second) / ql.params.QPS))
   var wg wait.Group
   for i := range actions { // action的数量为phases.replicasPerNamespace
      wg.Start(actions[i])
      time.Sleep(sleepDuration)
   }
   wg.Wait()
}
```


randomizedLoad: 每隔t秒创建一个pod，从代码中可知t的取值范围是[0,2)

```
func (rl *randomizedLoad) Execute(actions []func()) {
   var wg wait.Group
   for i := range actions {
      wg.Start(actions[i])
      time.Sleep(sleepDuration(rl.params.AverageQPS))
   }
   wg.Wait()
}

func sleepDuration(avgQPS float64) time.Duration {
   randomFactor := 2 * rand.Float64()
   return time.Duration(int(randomFactor * float64(time.Second) / avgQPS))
}
```



**SchedulingThroughput**

每measurmentInterval（默认5s）间隔计算一次每秒调度的pod数量（throughput）

```
go func() {
   defer ps.Stop()
   lastScheduledCount := 0
   for {
      select {
      case <-s.stopCh:
         return
      case <-time.After(measurmentInterval):
         pods, err := ps.List()
         if err != nil {
            // List in NewPodStore never returns error.
            // TODO(mborsz): Even if this is a case now, it doesn't need to be true in future. Refactor this.
            panic(fmt.Errorf("unexpected error on PodStore.List: %w", err))
         }
         podsStatus := measurementutil.ComputePodsStartupStatus(pods, 0, nil /* updatePodPredicate */)
         throughput := float64(podsStatus.Scheduled-lastScheduledCount) / float64(measurmentInterval/time.Second)
         s.schedulingThroughputs = append(s.schedulingThroughputs, throughput)
         lastScheduledCount = podsStatus.Scheduled
         klog.V(3).Infof("%v: %s: %d pods scheduled", s, selector.String(), lastScheduledCount)
      }
   }
}()
```

gather会对上述统计的throughput按大小排序，并计算第50、90、99、max(100)分位数

```
func (s *schedulingThroughputMeasurement) gather(threshold float64) ([]measurement.Summary, error) {
   if !s.isRunning {
      klog.Errorf("%s: measurement is not running", s)
      return nil, fmt.Errorf("measurement is not running")
   }
   s.stop()
   klog.V(2).Infof("%s: gathering data", s)

   throughputSummary := &schedulingThroughput{}
   if length := len(s.schedulingThroughputs); length > 0 {
      sort.Float64s(s.schedulingThroughputs)
      throughputSummary.Perc50 = s.schedulingThroughputs[int(math.Ceil(float64(length*50)/100))-1]
      throughputSummary.Perc90 = s.schedulingThroughputs[int(math.Ceil(float64(length*90)/100))-1]
      throughputSummary.Perc99 = s.schedulingThroughputs[int(math.Ceil(float64(length*99)/100))-1]
      throughputSummary.Max = s.schedulingThroughputs[length-1]
   }
   content, err := util.PrettyPrintJSON(throughputSummary)
   if err != nil {
      return nil, err
   }
   summary := measurement.CreateSummary(schedulingThroughputMeasurementName, "json", content)
   if threshold > 0 && throughputSummary.Max < threshold {
      err = errors.NewMetricViolationError(
         "scheduler throughput",
         fmt.Sprintf("actual throughput %f lower than threshold %f", throughputSummary.Max, threshold))
   }
   return []measurement.Summary{summary}, err
}
```


