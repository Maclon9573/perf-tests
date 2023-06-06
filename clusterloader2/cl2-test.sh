#!/bin/bash

set -o nounset
set -o pipefail

# 定义默认参数
testconfig=""
provider=""
kubeconfig=""
## 方案集合,每个方案由6个数字组成,分别表示:
# 1.节点数(kubemark)
# 2.每个节点workload数量
# 3.每个workload的pod数量;如果不使用kubemark,节点数设为0
# 4.每个真实节点的listpod workload数量
# 5.每个workload的listpod数量
# 6.每个listpod并发数量
schemes=(
  "15 20 20 20 1 10"
)
qps=""
report_dir=""
enable_prometheus_server="false"
prometheus_apiserver_scrape_port="6443"
prometheus_storage_class_provisioner=""
prometheus_pvc_storage_class=""
tear_down_prometheus_server="false"
enable_kubemark="true"

print_line() {
   echo "--------------------------------------------------------------------------------"
}

# 解析命令行选项和参数
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --kubeconfig)
      kubeconfig="$2"
      shift
      ;;
    --prometheus-apiserver-scrape-port)
      prometheus_apiserver_scrape_port="$2"
      shift
      ;;
    --prometheus-storage-class-provisioner)
      prometheus_storage_class_provisioner="$2"
      shift
      ;;
    --prometheus-pvc-storage-class)
      prometheus_pvc_storage_class="$2"
      shift
      ;;
    --tear-down-prometheus-server)
      tear_down_prometheus_server="$2"
      shift
      ;;
    --testconfig)
      testconfig="$2"
      shift
      ;;
    --provider)
      provider="$2"
      shift
      ;;
    --qps)
      qps="$2"
      shift
      ;;
    --enable-prometheus-server)
      enable_prometheus_server="$2"
      shift
      ;;
    --report-dir)
      report_dir="$2"
      shift
      ;;
    --enable-kubemark)
          enable_kubemark="$2"
          shift
          ;;
    *)
      # 对于未知的选项或参数进行其他处理，如果需要的话
      echo "未知选项或参数: $key"
      exit 1
      ;;
  esac
  shift
done

# 检查必需的参数
if [ -z "$testconfig" ] || [ -z "$provider" ] || [ -z "$kubeconfig" ] || [ -z "$qps" ] || [ -z "$report_dir" ]; then
  echo "必需的参数未提供."
  exit 1
fi

print_line
echo "Kubeconfig 文件: $kubeconfig"
echo "测试配置文件: $testconfig"
echo "提供者: $provider"
echo "QPS 设置为: $qps"
echo "是否启用 Prometheus 服务: $enable_prometheus_server"
echo "报告目录: $report_dir"
print_line

if [ $enable_kubemark = "true" ]; then
    # 检查kubemark yaml文件是否存在
    if [ ! -f "./kubemark-rc.yaml" ]; then
      echo "kubemark部署文件不存在."
      exit 1
    fi
fi

# 设置KUBECONFIG以执行kubectl
export KUBECONFIG=$kubeconfig

# 创建kubemark命名空间和secret
if ! $(kubectl create ns kubemark 2&>/dev/null); then
  echo 'namespaces kubemark already exists'
else
  echo 'created namespaces kubemark'
fi

if ! $(kubectl create secret generic kubeconfig --type=Opaque --namespace=kubemark \
       --from-file=kubelet.kubeconfig=$kubeconfig --from-file=kubeproxy.kubeconfig=$kubeconfig 2&>/dev/null); then
  echo 'secrets kubeconfig already exists'
else
  echo 'created secrets kubeconfig'
fi

# 创建listpods clusterRoleBinding
if [ ! -f "./listpods-clusterrolebinding.yaml" ]; then
  echo "listpods clusterRoleBinding文件不存在."
  exit 1
fi
if ! $(kubectl apply -f ./listpods-clusterrolebinding.yaml); then
  echo 'listpods clusterRoleBinding already exists'
else
  echo 'created listpods clusterRoleBinding'
fi

# 获取非kubemark节点数
real_nodes_count=$(kubectl get nodes |grep -w Ready |grep -v hollow| wc -l |sed 's/ //g')

# 遍历执行schemes
MAX_TIMEOUT=900  # kubemark hollow nodes满足条件超时时间，以秒为单位
index=1
for ((i=0; i<${#schemes[@]}; i++)); do
    values=(${schemes[$i]})
    nodes=${values[0]}
    workload=${values[1]}
    pods=${values[2]}
    listpods_workload=${values[3]}
    listpods=${values[4]}
    listpods_concurrency=${values[5]}

    # 等待kubemark hollow nodes满足条件
    sed -i "" "/replicas/s/replicas.*/replicas: ${nodes}/" ./kubemark-rc.yaml 2&>/dev/null # Macos
    sed -i "/replicas/s/replicas.*/replicas: ${nodes}/" ./kubemark-rc.yaml 2&>/dev/null # Linux
    kubectl apply -f ./kubemark-rc.yaml
    if [ $? -ne 0 ]; then
      echo "部署kubemark hollow nodes失败"
      exit 1
    fi
    start_time=$(date +%s)  # 记录开始时间的秒数
    while true; do
      running_hollow_nodes=$(kubectl get nodes| grep "hollow-node" |grep -cw Ready)
      end_time=$(date +%s)  # 记录结束时间的秒数
      execution_time=$((end_time - start_time))  # 计算命令执行时间

      if [ $running_hollow_nodes -eq $nodes ]; then
          echo "创建hollow nodes成功, hollow nodes数量${running_hollow_nodes}."
          kubectl get nodes| grep NotReady |grep "hollow-node" |awk '{print $1}' |xargs kubectl delete nodes 2&>/dev/null
          break
      elif [ $execution_time -ge $MAX_TIMEOUT ]; then
          # 超过15分钟，退出循环
          echo "等待hollow nodes满足条件超时,当前hollow nodes数量${running_hollow_nodes},期望数量${nodes}."
          exit 1
      else
          echo "等待hollow nodes满足条件...当前hollow nodes数量${running_hollow_nodes},期望数量${nodes}."
          sleep 5
      fi
    done

    print_line
    start_time=$(date +%s)
    current_date=$(date +"%Y-%m-%d-%H:%M:%S")
    echo "开始第${index}次测试,node数量: ${nodes}, workloads per node: ${workload}, pods per workload: ${pods}, 当前时间$current_date"
    # 在report_dir中创建子目录
    new_report_dir="${report_dir}/result_${nodes}_${workload}_${pods}_${listpods_workload}_${listpods}_${listpods_concurrency}-${current_date}"
    mkdir -p "${new_report_dir}"

    source ./cl2-env
    ./clusterloader2 \
      --nodes=$nodes \
      --enable-prometheus-server=${enable_prometheus_server} \
      --prometheus-apiserver-scrape-port=$prometheus_apiserver_scrape_port \
      --tear-down-prometheus-server=$tear_down_prometheus_server \
      --prometheus-scrape-master-kubelets=true \
      --testconfig="$testconfig" \
      --provider="$provider" \
      --kubeconfig="$kubeconfig" \
      --report-dir="$new_report_dir" \
      --v=2 2>&1 |tee $new_report_dir/cl2_test.log
    print_line

    test_result=$(tail -50 $new_report_dir/cl2_test.log |grep "Status" |grep -Eo "Success|Fail")
    end_time=$(date +%s)
    execution_time=$((end_time - start_time))
    # 检查 clusterloader2 的退出状态
    if [ "x$test_result" = "xFail" ]; then
      echo "第${index}次测试失败,node数量: ${nodes}, workloads per node: ${workload}, pods per workload: ${pods}, 测试耗时${execution_time}s"
      echo "clusterloader2执行失败，report_dir: $report_dir"
      print_line
      break
    elif [ "x$test_result" = "xSuccess" ]; then
      echo "第${index}次测试成功,node数量: ${nodes}, workloads per node: ${workload}, pods per workload: ${pods}, 测试耗时${execution_time}s"
      echo "clusterloader2执行成功，report_dir: $report_dir"
      print_line
      index=$((index + 1))
      continue
    else
      echo "第${index}次测试失败,node数量: ${nodes}, workloads per node: ${workload}, pods per workload: ${pods}, 无法获取测试结果"
      print_line
      exit 1
    fi
done

# 删除listpods clusterRoleBinding
kubectl delete -f listpods-clusterrolebinding.yaml
# 删除kubemark hollow ndoes
# kubectl delete rc -n kubemark hollow-node
# 删除NotReady状态的hollow nodes
kubectl get nodes| grep NotReady |grep "hollow-node" |awk '{print $1}' |xargs kubectl delete nodes 2&>/dev/null
