# kubemark集群创建

kubemark是K8S官方给出的性能测试工具，能够利用相当小的资源，模拟出一个大规模K8S集群。

## kubemark 架构

kubemark cluster 包括两部分： 一个真实的master集群和一系列 “hollow” node， "hollow node" 只是模拟了kubelet的行为，并不是真正的node，不会启动任何的pod和挂载卷。
一般搭建kubemark 测试集群需要一个真实的集群（external cluster）和一个 kubemark master。hollowNode 以pod的形式运行在 external cluster 中，并连接 kubemark master 将自己注册为kubemark master 的 node。

![image-20230516172610018](/Users/mcll/Library/Application Support/typora-user-images/image-20230516172610018.png)

## 搭建 kubemark 流程

说明：本教程只使用了一个集群

搭建详细流程参考[k8s 官方文档](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-scalability/kubemark-setup-guide.md)

1. 构建kubemark镜像

   - 拉取Kubernetes代码

     ```
     cd $GOPATH/src/k8s.io/
     git clone git@github.com:kubernetes/kubernetes.git
     ```

   - 编译二进制文件

     ```
     ./hack/build-go.sh cmd/kubemark/
     cp $GOPATH/src/k8s.io/kubernetes/_output/bin/kubemark $GOPATH/src/k8s.io/kubernetes/cluster/images/kubemark/
     ```

   - 构建镜像

     ```
     cd $GOPATH/src/k8s.io/kubernetes/cluster/images/kubemark/
     make build
     ```

   - 推送镜像到私有仓库

     ```
     docker tag staging-k8s.gcr.io/kubemark:latest {{kubemark_image_registry}}/kubemark:{{kubemark_image_tag}}
     docker push {{kubemark_image_registry}}/kubemark:{{kubemark_image_tag}}
     ```

   *注意事项:*

   - 最好使用跟自己集群版本相同的分支

   - 如果构建镜像时无法获取grc.io镜像，可使用alpine-glibc，或如下Dockerfile

     ```
     FROM maclonma/base:v1
     
     COPY kubemark /kubemark
     ```

2. 创建hollow节点

   - 创建namespace和secret

     ```
     kubectl create ns kubemark 
     kubectl create secret generic kubeconfig --type=Opaque --namespace=kubemark --from-file=kubelet.kubeconfig=path/to/kubeletcfg --from-file=kubeproxy.kubeconfig=path/to/kubeproxycfg
     ```

   - 部署yaml文件，创建hollow节点

     ```
     kubectl create -f hollow-node_simplified_template.yaml
     
     apiVersion: v1
     kind: ReplicationController
     metadata:
       name: hollow-node-2
       namespace: kubemark
     spec:
       replicas: 2
       selector:
           name: hollow-node-2
       template:
         metadata:
           labels:
             name: hollow-node-2
         spec:
           nodeSelector:		#添加node selector，防止后面创建的hollow node调度到之前创建的hollow node上
             kubernetes.io/hostname: k8s-node1
           initContainers:
           - name: init-inotify-limit
             image: docker.io/busybox:latest
             command: ['sysctl', '-w', 'fs.inotify.max_user_instances=200']
             securityContext:
               privileged: true
           volumes:
           - name: kubeconfig-volume
             secret:
               secretName: kubeconfig
           - name: logs-volume
             hostPath:
               path: /var/log
           containers:
           - name: hollow-kubelet
             image: maclonma/kubemark:v1.20
             ports:
             - containerPort: 4194
             - containerPort: 10250
             - containerPort: 10255
             env:
             - name: CONTENT_TYPE
               valueFrom:
                 configMapKeyRef:
                   name: node-configmap
                   key: content.type
             - name: NODE_NAME
               valueFrom:
                 fieldRef:
                   fieldPath: metadata.name
             command:
             - /kubemark
             args:
             - --morph=kubelet
             - --name=$(NODE_NAME)
             - --kubeconfig=/kubeconfig/kubelet.kubeconfig
             - --alsologtostderr
             - --v=2
             volumeMounts:
             - name: kubeconfig-volume
               mountPath: /kubeconfig
               readOnly: true
             - name: logs-volume
               mountPath: /var/log
             resources:
               requests:
                 cpu: 20m
                 memory: 50M
             securityContext:
               privileged: true
           - name: hollow-proxy
             image: maclonma/kubemark:v1.20
             env:
             - name: CONTENT_TYPE
               valueFrom:
                 configMapKeyRef:
                   name: node-configmap
                   key: content.type
             - name: NODE_NAME
               valueFrom:
                 fieldRef:
                   fieldPath: metadata.name
             command:
             - /kubemark
             args:
             - --morph=proxy
             - --name=$(NODE_NAME)
             - --use-real-proxier=false
             - --kubeconfig=/kubeconfig/kubeproxy.kubeconfig
             - --alsologtostderr
             - --v=2
             volumeMounts:
             - name: kubeconfig-volume
               mountPath: /kubeconfig
               readOnly: true
             - name: logs-volume
               mountPath: /var/log
             resources:
               requests:
                 cpu: 20m
                 memory: 50M
           tolerations:
           - effect: NoExecute
             key: node.kubernetes.io/unreachable
             operator: Exists
           - effect: NoExecute
             key: node.kubernetes.io/not-ready
             operator: Exists
     ```

## 可能遇到的问题

**遇到的问题**

1. 编译kubemark失败

   ```
   NOTE: ./hack/build-go.sh has been replaced by 'make' or 'make all'
   
   The equivalent of this invocation is:
       make WHAT='cmd/kube'
   
   
   make: *** No rule to make target 'all'.  Stop.
   ```

   **原因**：项目根目录下的Makefile和Makefile.generated_files应该为软连接文件

   **解决方法**：

   ```
   ln -sf ./build/root/Makefile Makefile
   ln -sf ./build/root/Makefile.generated_files Makefile.generated_files
   ```

2. 创建hollow节点失败
   - 可能使用了错误的yaml文件：https://github.com/kubernetes/community/issues/5475

3. 要为kubemark hollow nodes的ReplicationController添加nodeSelector以防止hollow nodes pods被调度到hollow nodes上。同理exec service的deployment模版也要添加nodeSelector

4. 由于kubemark中的kubelet使用http协议,而正常集群中的kubelet使用https协议.导致Prometheus无法正常获取kubemark的kubelet指标.
   - 可以单独为kubemark kubelet创建servicemonitor,并修改代码忽略相关报错
