/*
* Copyright (c) 2024 SwanLink (Jiangsu) Technology Development Co., LTD.
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import common from '@ohos.app.ability.common';
import { FlutterPage, Log } from '@ohos/flutter_ohos'
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent, { WantAgent } from '@ohos.app.ability.wantAgent';
import { BusinessError } from '@kit.BasicServicesKit';


let storage = LocalStorage.getShared()
const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS'


let wantAgentInfo: wantAgent.WantAgentInfo = {
  // 点击通知后，将要执行的动作列表
  // 添加需要被拉起应用的bundleName和abilityName
  wants: [
    {
      bundleName: "com.example.myapplication",
      abilityName: "om.example.myapplication.EntryAbility"
    }
  ],

  // 指定点击通知栏消息后的动作是拉起ability
  actionType: wantAgent.OperationType.START_ABILITY,
  // 使用者自定义的一个私有值
  requestCode: 0,
  // 点击通知后，动作执行属性
  wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
};

const TAG = 'Index'

@Entry(storage)
@Component
struct Index {
  private context = getContext(this) as common.UIAbilityContext
  @LocalStorageLink('viewId') viewId: string = "";

  build() {
    Column() {
      FlutterPage({ viewId: this.viewId })
    }
  }

  onBackPress(): boolean {
    this.context.eventHub.emit(EVENT_BACK_PRESS)
    return true
  }
}