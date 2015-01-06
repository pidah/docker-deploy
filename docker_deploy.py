#!/usr/bin/env python

"""
Docker zero-downtime deployment script based on
https://github.com/jwilder/nginx-proxy and docker's
offical API client.

"""


from __future__ import print_function
import socket
import sys
import os
import json
import requests
import time
from docker import Client

c = Client(base_url='unix://var/run/docker.sock', timeout=30)
APP_NAME = os.environ['APP_NAME']
GIT_COMMIT_ID = os.environ['GIT_COMMIT_ID']
COUNTDOWN = int(os.environ['COUNTDOWN'])
REGISTRY = 'registry.devops101.com'


def pre_deploy_check():
    print('>>>Running pre-deployment checks')
    print(os.environ['GIT_COMMIT_ID'])
    print(os.environ['APP_NAME'])


def running_containers():
    try:
        print('Listing currently running containers:')
        running_containers = c.containers()
        print(running_containers)
    except Exception as err:
        sys.stderr.write('ERROR: %s\n' % str(err))
        print('Ensure docker is running on the host.')
        sys.exit(2)


def old_app_container_id():
    print('>>>Get old app container ID')
    try:
        old_app_container_id = ", ".join(
            [x['Id'] for x in c.containers() if x['Command'].endswith('my_init')])
        print(old_app_container_id)
        return old_app_container_id
    except Exception as err:
        sys.stderr.write('ERROR: %s\n' % str(err))
        print('app_container not currently running.')


def start_nginx_container():
    print('>>>Start nginx container')
    if 'forego' in str(c.containers()):
        print('nginx container is already running.')
    else:
        for line in c.pull(
                '{0}/nginx-{1}:{2}'.format(REGISTRY, APP_NAME, GIT_COMMIT_ID),
                stream=True):
            print(json.dumps(json.loads(line), indent=4))

        nginx_container = c.create_container(
            image='{0}/nginx-{1}:{2}'.format(REGISTRY, APP_NAME, GIT_COMMIT_ID),
            command=[
                'forego',
                'start',
                '-r'],
            volumes=['/tmp/docker.sock'],
            ports=[80])
        print(nginx_container)
        nginx_container_id = nginx_container.get('Id')
        print(nginx_container_id)
        response = c.start(
            nginx_container_id,
            port_bindings={80: ('0.0.0.0', 80)},
            binds={'/var/run/docker.sock': {'bind': '/tmp/docker.sock', 'ro': False}})
        details = c.inspect_container(nginx_container)
        ip = details['NetworkSettings']['IPAddress']
        print(ip)


def start_new_app_container():

    print('>>>Starting new app container')
    for line in c.pull(
            '{0}/{1}:{2}'.format(REGISTRY, APP_NAME, GIT_COMMIT_ID), stream=True):
        print(json.dumps(json.loads(line), indent=4))

    with open("/etc/docker_env", "r") as f:
        docker_env_var = f.readlines()

    new_app_container = c.create_container(
        image='{0}/{1}:{2}'.format(REGISTRY, APP_NAME, GIT_COMMIT_ID),
        command=['/sbin/my_init'],
        volumes=['/var/log/wsgi'],
        ports=[80],
        environment=docker_env_var
    )
    print(new_app_container)
    new_app_container_id = new_app_container.get('Id')
    print(new_app_container_id)
    response = c.start(
        new_app_container_id,
        binds={'/var/log/wsgi': {'bind': '/var/log/wsgi', 'ro': False}})
    details = c.inspect_container(new_app_container)
    new_app_container_ip = details['NetworkSettings']['IPAddress']
    print(new_app_container_ip)
    return new_app_container_ip


def post_deploy_check(container):
    print('>>>Running post-deploy app check')
    if APP_NAME == 'shop_backend':
        url = "http://{0}//admin/".format(container)
    else:
        url = "http://{0}".format(container)

    response = requests.get(url)

    if response.status_code == 200:
        print('The Application started successfully.')
    else:
        print(
            'Error: The container returned an unexpected HTTP Status Code %d' %
            (response.status_code))
        sys.exit(1)


def stop_old_container(container):
    print('>>>Stopping old container')
    try:
        [c.stop(i, timeout=10) for i in container.split(", ")]
    except Exception as err:
        sys.stderr.write('ERROR: %s\n' % str(err))
        print('Cannot stop old container.')


def countdown(count):
    while (count >= 0):
        print ('Post-deploy app checks will start in %d seconds' % count)
        count -= 1
        time.sleep(1)

if __name__ == "__main__":
    pre_deploy_check()
    running_containers()
    old_app_container_id = old_app_container_id()
    start_nginx_container()
    new_container_ip = start_new_app_container()
    countdown(COUNTDOWN)
    post_deploy_check(new_container_ip)
    stop_old_container(old_app_container_id)
