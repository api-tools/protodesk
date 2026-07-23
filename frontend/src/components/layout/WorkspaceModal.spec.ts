import {describe, expect, it} from 'vitest'
import {mount} from '@vue/test-utils'
import WorkspaceModal from './WorkspaceModal.vue'

describe('WorkspaceModal', () => {
  it('emits import and export actions', async () => {
    const wrapper = mount(WorkspaceModal, {
      props: {
        open: true,
        loading: false,
        result: null,
      },
      global: {
        stubs: {
          Teleport: true,
        },
      },
    })

    await clickButton(wrapper, 'Export workspace')
    await clickButton(wrapper, 'Import workspace')

    expect(wrapper.emitted('exportWorkspace')).toHaveLength(1)
    expect(wrapper.emitted('importWorkspace')).toHaveLength(1)
  })

  it('renders transfer result summary', () => {
    const wrapper = mount(WorkspaceModal, {
      props: {
        open: true,
        loading: false,
        result: {
          path: '/tmp/protodesk-workspace.json',
          serverCount: 2,
          collectionCount: 3,
          savedRequestCount: 4,
        },
      },
      global: {
        stubs: {
          Teleport: true,
        },
      },
    })

    expect(wrapper.text()).toContain('Servers')
    expect(wrapper.text()).toContain('2')
    expect(wrapper.text()).toContain('Collections')
    expect(wrapper.text()).toContain('3')
    expect(wrapper.text()).toContain('Saved requests')
    expect(wrapper.text()).toContain('4')
  })
})

async function clickButton(wrapper: ReturnType<typeof mount>, label: string) {
  const button = wrapper.findAll('button').find((candidate) => candidate.text().includes(label))
  expect(button, `button "${label}"`).toBeTruthy()
  await button!.trigger('click')
}
