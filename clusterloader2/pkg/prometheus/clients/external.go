/*
Copyright 2022 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package prom

import (
	"fmt"
	"io/ioutil"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

type externalPrometheusClient struct {
	client *http.Client
	req    *http.Request
}

var _ Client = &externalPrometheusClient{}

func (c *externalPrometheusClient) Query(query string, queryTime time.Time) ([]byte, error) {
	params := url.Values{}
	params.Add("query", query)
	params.Add("time", queryTime.Format(time.RFC3339))
	c.req.URL.RawQuery = params.Encode()
	resp, err := c.client.Do(c.req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	resBody, err := ioutil.ReadAll(resp.Body)
	if statusCode := resp.StatusCode; statusCode > 299 {
		return resBody, fmt.Errorf("response failed with status code %d", statusCode)
	}
	if err != nil {
		return nil, err
	}
	return resBody, nil
}

// NewExternalPrometheusClient returns a http client for talking to external prometheus server.
func NewExternalPrometheusClient() (Client, error) {
	prometheusHost := os.Getenv("EXTERNAL_PROMETHEUS_HOST")
	prometheusRequestHeader := os.Getenv("EXTERNAL_PROMETHEUS_REQUEST_HEADER")
	if prometheusHost == "" {
		return nil, fmt.Errorf("prometheus host is not set")
	}

	client := &http.Client{}
	req, err := http.NewRequest("GET", prometheusHost, nil)
	if err != nil {
		return nil, err
	}

	if prometheusRequestHeader != "" {
		headers := strings.Split(prometheusRequestHeader, ";")
		for _, header := range headers {
			kv := strings.Split(header, ":")
			if len(kv) != 2 {
				return nil, fmt.Errorf("the format of external prometheus header is wrong")
			}
			req.Header.Set(kv[0], strings.TrimSpace(kv[1]))
		}
	}

	return &externalPrometheusClient{
		client: client,
		req:    req,
	}, nil
}
