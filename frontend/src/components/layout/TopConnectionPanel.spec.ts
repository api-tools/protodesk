import {describe, expect, it} from 'vitest'
import {mount} from '@vue/test-utils'
import TopConnectionPanel from './TopConnectionPanel.vue'

describe('TopConnectionPanel', () => {
  it('keeps all management actions in the visible toolbar and emits them', async () => {
    const wrapper = mount(TopConnectionPanel, {
      props: {
        servers: [{
          workspaceId: 'local',
          id: 'server-1',
          name: 'A very long local gRPC server profile name',
          address: 'localhost:50051',
          tlsEnabled: false,
          reflectionEnabled: true,
          protoFiles: [],
          protoFolders: [],
          metadataJson: '{}',
        }],
        selectedServerId: 'server-1',
        connectionState: 'connected',
      },
    })

    const actions = wrapper.find('.top-panel-actions')
    expect(actions.text()).toContain('Workspace')
    expect(actions.text()).toContain('Collections')
    expect(actions.text()).toContain('Servers')

    await clickButton(wrapper, 'Workspace')
    await clickButton(wrapper, 'Collections')
    await clickButton(wrapper, 'Servers')

    expect(wrapper.emitted('openWorkspace')).toHaveLength(1)
    expect(wrapper.emitted('openCollections')).toHaveLength(1)
    expect(wrapper.emitted('openServers')).toHaveLength(1)
  })
})

async function clickButton(wrapper: ReturnType<typeof mount>, label: string) {
  const button = wrapper.findAll('button').find((candidate) => candidate.text().includes(label))
  expect(button).toBeTruthy()
  await button!.trigger('click')
}
