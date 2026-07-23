import {describe, expect, it} from 'vitest'
import {mount} from '@vue/test-utils'
import MethodsPanel from './MethodsPanel.vue'
import type {GrpcMethod, GrpcService} from '../../types/grpc'

const pingMethod: GrpcMethod = {
  serviceName: 'fieldlab.FieldLabService',
  methodName: 'Ping',
  fullName: '/fieldlab.FieldLabService/Ping',
  requestType: 'fieldlab.PingRequest',
  responseType: 'fieldlab.PingResponse',
  clientStreaming: false,
  serverStreaming: false,
  requestFields: [],
}

const auditMethod: GrpcMethod = {
  serviceName: 'fieldlab.admin.AdminService',
  methodName: 'ListAuditEvents',
  fullName: '/fieldlab.admin.AdminService/ListAuditEvents',
  requestType: 'fieldlab.admin.ListAuditEventsRequest',
  responseType: 'fieldlab.admin.ListAuditEventsResponse',
  clientStreaming: false,
  serverStreaming: false,
  requestFields: [],
}

const services: GrpcService[] = [
  {name: 'fieldlab.FieldLabService', methods: [pingMethod]},
  {name: 'fieldlab.admin.AdminService', methods: [auditMethod]},
]

describe('MethodsPanel', () => {
  it('shows service and method counts in the bottom status bar', () => {
    const wrapper = mount(MethodsPanel, {
      props: {
        services,
        selectedMethod: null,
        connected: true,
        reflectionUnavailable: false,
      },
    })

    expect(wrapper.find('.methods-header').text()).toBe('Methods')
    expect(wrapper.find('.methods-status-bar').text()).toContain('2 services')
    expect(wrapper.find('.methods-status-bar').text()).toContain('2 methods')
  })

  it('renders proto fallback services even when reflection is unavailable', () => {
    const wrapper = mount(MethodsPanel, {
      props: {
        services,
        selectedMethod: null,
        connected: true,
        reflectionUnavailable: true,
      },
    })

    expect(wrapper.text()).toContain('fieldlab.FieldLabService')
    expect(wrapper.text()).toContain('Ping')
    expect(wrapper.text()).not.toContain('No methods available')
  })

  it('shows a proto-specific empty state when sources fail', () => {
    const wrapper = mount(MethodsPanel, {
      props: {
        services: [],
        selectedMethod: null,
        connected: true,
        reflectionUnavailable: false,
        protoSourceError: 'broken proto',
      },
    })

    expect(wrapper.text()).toContain('configured proto sources could not be loaded')
  })

  it('filters methods while keeping their parent service name', async () => {
    const wrapper = mount(MethodsPanel, {
      props: {
        services,
        selectedMethod: null,
        connected: true,
        reflectionUnavailable: false,
      },
    })

    await wrapper.find('input[type="search"]').setValue('audit')

    expect(wrapper.text()).toContain('fieldlab.admin.AdminService')
    expect(wrapper.text()).toContain('ListAuditEvents')
    expect(wrapper.text()).not.toContain('fieldlab.FieldLabService')
    expect(wrapper.text()).not.toContain('Ping')
  })

  it('collapses and expands service methods while preserving row selection emission', async () => {
    const wrapper = mount(MethodsPanel, {
      props: {
        services,
        selectedMethod: pingMethod,
        connected: true,
        reflectionUnavailable: false,
      },
    })

    expect(wrapper.find('.method-row.selected').text()).toContain('Ping')

    await wrapper.find('.service-toggle').trigger('click')
    expect(wrapper.text()).not.toContain('Ping')

    await wrapper.find('.service-toggle').trigger('click')
    await wrapper.find('.method-row').trigger('click')

    expect(wrapper.emitted('selectMethod')?.[0]).toEqual([pingMethod])
  })
})
