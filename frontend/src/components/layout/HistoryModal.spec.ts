import {describe, expect, it, vi} from 'vitest'
import {mount} from '@vue/test-utils'
import HistoryModal from './HistoryModal.vue'
import type {HistoryItem} from '../../types/grpc'

vi.mock('../../../wailsjs/runtime/runtime', () => ({
  ClipboardSetText: vi.fn(),
}))

const item: HistoryItem = {
  workspaceId: 'local',
  id: 'history-1',
  serverId: 'local-default',
  serverName: 'Local gRPC',
  serverAddress: 'localhost:50051',
  serviceName: 'fieldlab.admin.AdminService',
  methodName: 'ListTenants',
  fullMethod: '/fieldlab.admin.AdminService/ListTenants',
  requestJson: '{\n  "pageSize": 10\n}',
  requestMetadataJson: '{"authorization":"Bearer test"}',
  responseJson: '{\n  "tenants": []\n}',
  statusCode: 'OK',
  statusMessage: 'ok',
  durationMs: 2,
  createdAt: '2026-06-18T20:00:00Z',
}

describe('HistoryModal', () => {
  it('lists history items and previews the selected item', () => {
    const wrapper = mount(HistoryModal, {
      props: {
        open: true,
        items: [item],
        selectedItem: item,
        loading: false,
      },
      global: {
        stubs: {
          Teleport: true,
        },
      },
    })

    expect(wrapper.text()).toContain('Invocation History')
    expect(wrapper.text()).toContain('ListTenants')
    expect(wrapper.text()).toContain('localhost:50051')
    expect(wrapper.text()).toContain('"pageSize": 10')
    expect(wrapper.text()).toContain('"tenants": []')
  })

  it('emits load, delete, clear, and select actions', async () => {
    const wrapper = mount(HistoryModal, {
      props: {
        open: true,
        items: [item],
        selectedItem: item,
        loading: false,
      },
      global: {
        stubs: {
          Teleport: true,
        },
      },
    })

    await wrapper.find('.history-row').trigger('click')
    await clickButton(wrapper, 'Load request')
    await clickButton(wrapper, 'Save as request')
    await clickButton(wrapper, 'Delete')
    await clickButton(wrapper, 'Clear')

    expect(wrapper.emitted('select')?.[0]).toEqual([item.id])
    expect(wrapper.emitted('loadRequest')?.[0]).toEqual([item])
    expect(wrapper.emitted('saveAsRequest')?.[0]).toEqual([item, '', item.methodName])
    expect(wrapper.emitted('delete')?.[0]).toEqual([item.id])
    expect(wrapper.emitted('clear')).toHaveLength(1)
  })

  it('copies the selected history response body', async () => {
    const {ClipboardSetText} = await import('../../../wailsjs/runtime/runtime')
    const wrapper = mount(HistoryModal, {
      props: {
        open: true,
        items: [item],
        selectedItem: item,
        loading: false,
      },
      global: {
        stubs: {
          Teleport: true,
        },
      },
    })

    await clickButton(wrapper, 'Copy response')

    expect(ClipboardSetText).toHaveBeenCalledWith(item.responseJson)
  })
})

async function clickButton(wrapper: ReturnType<typeof mount>, label: string) {
  const button = wrapper.findAll('button').find((candidate) => candidate.text().includes(label))
  expect(button, `button "${label}"`).toBeTruthy()
  await button!.trigger('click')
}
