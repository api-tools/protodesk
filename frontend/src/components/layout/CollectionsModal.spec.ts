import {describe, expect, it} from 'vitest'
import {mount} from '@vue/test-utils'
import CollectionsModal from './CollectionsModal.vue'
import type {Collection} from '../../types/grpc'

const collection: Collection = {
  workspaceId: 'local',
  id: 'collection-1',
  name: 'Personal',
  description: '',
  createdAt: '2026-06-19T07:00:00Z',
  updatedAt: '2026-06-19T07:00:00Z',
  requests: [{
    workspaceId: 'local',
    id: 'request-1',
    collectionId: 'collection-1',
    name: 'List tenants',
    serverId: 'local-default',
    serverName: 'Local gRPC',
    serverAddress: 'localhost:50051',
    serviceName: 'fieldlab.admin.AdminService',
    methodName: 'ListTenants',
    fullMethod: '/fieldlab.admin.AdminService/ListTenants',
    requestJson: '{\n  "pageSize": 10\n}',
    requestMetadataJson: '{}',
    createdAt: '2026-06-19T07:00:00Z',
    updatedAt: '2026-06-19T07:00:00Z',
  }],
}

describe('CollectionsModal', () => {
  it('lists collections, previews requests, and emits actions', async () => {
    const wrapper = mount(CollectionsModal, {
      props: {
        open: true,
        collections: [collection],
        selectedCollection: collection,
        selectedRequest: collection.requests[0],
        loading: false,
        canSaveCurrent: true,
        defaultRequestName: 'ListTenants',
      },
      global: {
        stubs: {
          Teleport: true,
        },
      },
    })

    expect(wrapper.text()).toContain('Collections')
    expect(wrapper.text()).toContain('Personal')
    expect(wrapper.text()).toContain('List tenants')
    expect(wrapper.text()).toContain('"pageSize": 10')

    await wrapper.find('.history-row').trigger('click')
    await wrapper.find('.collection-request-row').trigger('click')
    await clickButton(wrapper, 'Save current request')
    await clickButton(wrapper, 'Load request')
    await clickButton(wrapper, 'Delete request')

    expect(wrapper.emitted('selectCollection')?.[0]).toEqual([collection.id])
    expect(wrapper.emitted('selectRequest')?.[0]).toEqual([collection.requests[0].id])
    expect(wrapper.emitted('saveCurrent')?.[0]).toEqual([collection.id, 'ListTenants'])
    expect(wrapper.emitted('load')?.[0]).toEqual([collection.requests[0]])
    expect(wrapper.emitted('deleteRequest')?.[0]).toEqual([collection.requests[0].id])
  })

  it('creates a default collection from the empty state', async () => {
    const wrapper = mount(CollectionsModal, {
      props: {
        open: true,
        collections: [],
        selectedCollection: null,
        selectedRequest: null,
        loading: false,
        canSaveCurrent: false,
        defaultRequestName: '',
      },
      global: {
        stubs: {
          Teleport: true,
        },
      },
    })

    await wrapper.find('[aria-label="Create collection"]').trigger('click')

    expect(wrapper.emitted('createCollection')?.[0]).toEqual(['Personal', ''])
  })
})

async function clickButton(wrapper: ReturnType<typeof mount>, label: string) {
  const button = wrapper.findAll('button').find((candidate) => candidate.text().includes(label))
  expect(button, `button "${label}"`).toBeTruthy()
  await button!.trigger('click')
}
